#!/usr/bin/env python3
"""EdgeCat eval runner (UI-free).

Drives an ADB-connected device through a dataset of tasks by invoking the hidden
EvalActivity directly — no uiautomator, no coordinate taps, no chat UI. Pulls the
TraceRecorder output per run_id and scores each run against structural/state/perf criteria.

Preconditions (enforced, not worked around):
  - A model must already be loaded in the main app (selected and initialized).
    The eval fails fast on a missing model rather than auto-loading a default —
    the run must reflect production configuration.

Usage:
    python android-app/test/eval/run.py [options]

    # First-time setup: open the app, pick and fully initialize a model, then:
    python android-app/test/eval/run.py --dataset datasets/v1_basic.jsonl --label main

    # One task:
    python android-app/test/eval/run.py --dataset datasets/v1_basic.jsonl --task calc-001

    # With explicit device serial:
    python android-app/test/eval/run.py --dataset datasets/v1_basic.jsonl --serial R3CW30Q4WFM

Output:
    runs/<label>-<ts>/
        results.json        aggregate metrics + per-task rows
        report.md           human-readable summary
        traces/<id>.jsonl   raw device traces (one per task, named by task id)
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from scorers import structural as s_struct  # noqa: E402
from scorers import state as s_state  # noqa: E402
from scorers import perf as s_perf  # noqa: E402

PKG = "com.edgecat.app"
EVAL_ACTIVITY = f"{PKG}/.eval.EvalActivity"
EVAL_ACTION = "com.edgecat.app.EVAL_RUN"
# EvalActivity writes to app-private external files dir so the app can write on
# scoped-storage Android without MANAGE_EXTERNAL_STORAGE. adb can still read it.
TRACE_DIR_ON_DEVICE = f"/sdcard/Android/data/{PKG}/files/edgecat-traces"
DEFAULT_ADB = "/Users/nali/Library/Android/sdk/platform-tools/adb"


# ---------------------------------------------------------------- ADB helpers


def adb_base(serial: str | None) -> list[str]:
    adb = os.environ.get("ADB", DEFAULT_ADB)
    if not Path(adb).exists():
        adb = shutil.which("adb") or "adb"
    base = [adb]
    if serial:
        base += ["-s", serial]
    return base


def sh(cmd: list[str], timeout: int = 30) -> tuple[int, str]:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "timeout"


def adb_shell(adb: list[str], cmd: str, timeout: int = 10) -> tuple[int, str]:
    return sh(adb + ["shell", cmd], timeout=timeout)


# ------------------------------------------------------------- Device setup


def ensure_device(adb: list[str]) -> None:
    code, out = sh(adb + ["get-state"], timeout=5)
    if code != 0 or "device" not in out:
        print("ERROR: no device connected.", file=sys.stderr)
        print(out, file=sys.stderr)
        sys.exit(2)


def ensure_trace_dir(adb: list[str]) -> None:
    # Do NOT pre-create the directory as `shell` — it then gets owned by shell with perms
    # the app can't write through under scoped storage. The app itself creates the dir
    # via TraceRecorder.forRunId (context.getExternalFilesDir) on first write.
    pass


# Runtime-dangerous permissions declared in AndroidManifest.xml. EvalActivity
# runs headlessly and cannot surface Android's permission dialogs, so any
# native skill that touches a gated ContentProvider/API hangs until the task
# timeout. Pre-granting via `pm grant` lets the skill succeed or fail fast
# instead of silently blocking the whole run.
RUNTIME_PERMISSIONS = [
    "android.permission.RECORD_AUDIO",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.SEND_SMS",
    "android.permission.READ_SMS",
    "android.permission.READ_CALENDAR",
    "android.permission.WRITE_CALENDAR",
    "android.permission.READ_CONTACTS",
    "android.permission.READ_MEDIA_IMAGES",
    "android.permission.READ_EXTERNAL_STORAGE",
    "android.permission.CALL_PHONE",
    "android.permission.ACCESS_FINE_LOCATION",
    "android.permission.ACCESS_COARSE_LOCATION",
]

# Special-case ops that are not granted via `pm grant` — these are AppOps.
APPOPS_GRANTS = [
    "WRITE_SETTINGS",
]


def preflight_permissions(adb: list[str]) -> None:
    """Pre-grant runtime permissions so headless EvalActivity doesn't hang on
    permission dialogs. Silently ignores permissions the device rejects (e.g.
    POST_NOTIFICATIONS only exists on API 33+, READ_EXTERNAL_STORAGE only on
    API <= 32)."""
    granted = 0
    skipped = 0
    for perm in RUNTIME_PERMISSIONS:
        code, out = adb_shell(adb, f"pm grant {PKG} {perm}", timeout=10)
        if code == 0 and "Exception" not in out and "Failure" not in out:
            granted += 1
        else:
            skipped += 1
    for op in APPOPS_GRANTS:
        adb_shell(adb, f"appops set {PKG} {op} allow", timeout=10)
    print(f"Preflight: granted {granted} permissions ({skipped} skipped, n/a on this API)")


def remove_trace_if_exists(adb: list[str], run_id: str) -> None:
    adb_shell(adb, f"rm -f {TRACE_DIR_ON_DEVICE}/{run_id}.jsonl")


# ---------------------------------------------------- Invoke EvalActivity


def escape_for_am(s: str) -> str:
    """Escape a string for `adb shell am start --es`.
    The outer shell is /system/bin/sh; we wrap the value in single quotes and
    escape embedded single quotes via the standard '\'' technique. We also avoid
    interpreting $ and backticks by keeping single-quote wrapping. Line breaks
    are replaced with spaces — prompts are single-line.
    """
    cleaned = s.replace("\r", " ").replace("\n", " ")
    return "'" + cleaned.replace("'", "'\\''") + "'"


def start_eval(adb: list[str], prompt: str, run_id: str) -> tuple[int, str]:
    # Requirement #4 + memory hygiene: fresh process per task. Gemma-4-E2B-it holds
    # ~2.4GB of native memory; without a force-stop, the second task's init hits
    # `Not enough free memory`.
    adb_shell(adb, f"am force-stop {PKG}", timeout=15)
    # Wait for the process to actually die. force-stop returns before all native
    # threads exit; racing am start against cleanup yields an activity that never
    # writes a trace (observed as no_trace_within_timeout in the multi-task loop).
    for _ in range(15):
        code, out = adb_shell(adb, f"pidof {PKG}", timeout=5)
        if not out.strip():
            break
        time.sleep(1)
    cmd = (
        f"am start -W "
        f"-a {EVAL_ACTION} "
        f"-n {EVAL_ACTIVITY} "
        f"--es prompt {escape_for_am(prompt)} "
        f"--es run_id {escape_for_am(run_id)}"
    )
    return adb_shell(adb, cmd, timeout=30)


# ---------------------------------------------------------- Trace polling


def wait_for_trace(adb: list[str], run_id: str, timeout_s: int) -> bool:
    """Poll for a completed trace file by run_id. Returns True when the file
    stops growing (flush complete)."""
    remote = f"{TRACE_DIR_ON_DEVICE}/{run_id}.jsonl"
    deadline = time.time() + timeout_s
    last_size = -1
    stable_ticks = 0
    while time.time() < deadline:
        code, out = adb_shell(adb, f"stat -c %s {remote} 2>/dev/null")
        size_str = out.strip()
        if size_str.isdigit():
            size = int(size_str)
            if size > 0 and size == last_size:
                stable_ticks += 1
                if stable_ticks >= 2:
                    return True
            else:
                stable_ticks = 0
                last_size = size
        time.sleep(2)
    return False


def pull_trace(adb: list[str], run_id: str, local: Path) -> bool:
    local.parent.mkdir(parents=True, exist_ok=True)
    remote = f"{TRACE_DIR_ON_DEVICE}/{run_id}.jsonl"
    code, _ = sh(adb + ["pull", remote, str(local)], timeout=15)
    return code == 0 and local.exists()


def parse_trace(path: Path) -> dict[str, Any]:
    """Trace is JSONL with one 'run' object + N 'span' objects. Flatten to a dict."""
    run: dict[str, Any] | None = None
    spans: list[dict[str, Any]] = []
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("type") == "run":
                run = obj.get("run")
            elif obj.get("type") == "span":
                spans.append(obj.get("span") or {})
    return {"run": run or {}, "spans": spans}


# ---------------------------------------------------------- Scoring pipeline


def extract_failure_info(trace: dict[str, Any]) -> dict[str, Any]:
    """Pick the first non-COMPLETED plan step and the evaluator's disagreement
    (if any) out of a trace, so the report can point at *where* a task broke
    instead of just reporting aggregate scores.

    Returned shape (all optional):
      failed_step: {id, skill, description, status, error} | None
      eval_assessment: str | None     (only when evaluation.goal_achieved is False)
      eval_missing: list[str]
      eval_failed_criteria: list[str]
    """
    run = trace.get("run") or {}
    plan = run.get("plan") or {}
    step_results = run.get("step_results") or {}

    failed_step: dict[str, Any] | None = None
    # Walk plan.steps (ordered list) rather than step_results (dict) so we
    # deterministically report the earliest failing step, even on runtimes
    # where dict insertion order isn't preserved.
    for step in plan.get("steps") or []:
        sid = step.get("id")
        if not sid:
            continue
        sr = step_results.get(sid)
        if sr is None:
            # Planned but never executed — treat as the failure point (the
            # prior step likely aborted or the orchestrator gave up).
            failed_step = {
                "id": sid,
                "skill": step.get("skill_name") or step.get("tool_name"),
                "description": step.get("description"),
                "status": "NOT_EXECUTED",
                "error": None,
            }
            break
        status = (sr.get("status") or "").upper()
        err = sr.get("error")
        if status != "COMPLETED" or err:
            failed_step = {
                "id": sid,
                "skill": step.get("skill_name") or step.get("tool_name"),
                "description": step.get("description"),
                "status": status or "UNKNOWN",
                "error": err,
            }
            break

    eval_res = run.get("evaluation") or {}
    eval_assessment: str | None = None
    eval_missing: list[str] = []
    eval_failed_criteria: list[str] = []
    if eval_res and eval_res.get("goal_achieved") is False:
        eval_assessment = eval_res.get("assessment")
        eval_missing = list(eval_res.get("missing_items") or [])
        eval_failed_criteria = list(eval_res.get("failed_criteria") or [])

    return {
        "failed_step": failed_step,
        "eval_assessment": eval_assessment,
        "eval_missing": eval_missing,
        "eval_failed_criteria": eval_failed_criteria,
    }


def _empty_failure_info() -> dict[str, Any]:
    return {
        "failed_step": None,
        "eval_assessment": None,
        "eval_missing": [],
        "eval_failed_criteria": [],
    }


def _failure_row(task: dict[str, Any], error: str, detail: str) -> dict[str, Any]:
    """Build a zero-score row shaped like score_task output, so summary/report code
    doesn't need to special-case failures."""
    return {
        "task_id": task["id"],
        "prompt": task["prompt"],
        "category": task.get("category"),
        "complexity": task.get("complexity", "unknown"),
        "error": error,
        "tsr": 0.0,
        "scores": {
            "plan_validity": 0.0,
            "tool_correctness": 0.0,
            "step_order": 0.0,
            "refusal_accuracy": 0.0,
            "replan_convergence": 0.0,
            "evaluator_rubber_stamp_ok": 0.0,
        },
        "state_verifier": {"type": None, "passed": None, "detail": detail},
        "details": {
            "plan_validity": None,
            "tool_correctness": None,
            "step_order": None,
            "refusal_accuracy": None,
            "replan_convergence": None,
            "rubber_stamp": None,
        },
        "failure_info": _empty_failure_info(),
        "perf": {
            "latency": {"total_ms": 0},
            "thermal_events": 0,
            "peak_mem_mb": 0,
            "tokens_per_sec": 0.0,
            "budget_ms": int(task.get("budget_ms", int(task.get("timeout_s", 180)) * 500)),
            "latency_ok": None,
            "latency_overshoot_ms": 0,
        },
        "iteration": 0,
        "final_status": "error",
    }


def score_task(
    task: dict[str, Any],
    trace: dict[str, Any],
    adb: list[str],
    enforce_latency_budget: bool = False,
) -> dict[str, Any]:
    """Run all scorers against a single trace. Returns a per-task result row."""
    result: dict[str, Any] = {
        "task_id": task["id"],
        "prompt": task["prompt"],
        "category": task.get("category"),
        "complexity": task.get("complexity"),
    }

    pv_score, pv_detail = s_struct.plan_validity(trace)
    tc_score, tc_detail = s_struct.tool_correctness(trace, task.get("expected_skills") or [])
    so_score, so_detail = s_struct.step_order_lcs(trace, task.get("expected_skills") or [])
    rf_score, rf_detail = s_struct.refusal_accuracy(trace, task.get("should_refuse", False))
    rc_score, rc_detail = s_struct.replan_convergence(trace)

    verifier = task.get("verifier") or {}
    state_passed, state_detail = s_state.run_verifier(adb, trace, verifier)

    rs_score, rs_detail = s_struct.evaluator_rubber_stamp(trace, state_passed)

    lat = s_perf.latency_stats(trace)
    therm_count, _ = s_perf.thermal_events(trace)
    peak_mb = s_perf.peak_memory_mb(trace)
    tps = s_perf.tokens_per_sec(trace)

    # Latency budget gate: informational by default, TSR-affecting when
    # --enforce-latency-budget is set. Default budget is half the hard timeout
    # (so a 120s timeout → 60s budget) — tasks that cut it fine should still
    # flag even if they squeak under the wall-clock timeout.
    timeout_s = int(task.get("timeout_s", 180))
    budget_ms = int(task.get("budget_ms", timeout_s * 500))
    total_ms = int(lat.get("total_ms", 0))
    latency_ok = (total_ms <= budget_ms) if total_ms > 0 else True
    latency_overshoot_ms = max(0, total_ms - budget_ms)

    if state_passed is True:
        tsr = 1.0
    elif state_passed is False:
        tsr = 0.0
    else:
        run = trace.get("run") or {}
        eval_res = run.get("evaluation") or {}
        tsr = 1.0 if eval_res.get("goal_achieved") else 0.0

    if enforce_latency_budget and tsr == 1.0 and not latency_ok:
        tsr = 0.0

    result.update({
        "tsr": tsr,
        "scores": {
            "plan_validity": pv_score,
            "tool_correctness": tc_score,
            "step_order": so_score,
            "refusal_accuracy": rf_score,
            "replan_convergence": rc_score,
            "evaluator_rubber_stamp_ok": rs_score,
        },
        "state_verifier": {
            "type": verifier.get("type"),
            "passed": state_passed,
            "detail": state_detail,
        },
        "details": {
            "plan_validity": pv_detail,
            "tool_correctness": tc_detail,
            "step_order": so_detail,
            "refusal_accuracy": rf_detail,
            "replan_convergence": rc_detail,
            "rubber_stamp": rs_detail,
        },
        "failure_info": extract_failure_info(trace),
        "perf": {
            "latency": lat,
            "thermal_events": therm_count,
            "peak_mem_mb": peak_mb,
            "tokens_per_sec": round(tps, 2),
            "budget_ms": budget_ms,
            "latency_ok": latency_ok,
            "latency_overshoot_ms": latency_overshoot_ms,
        },
        "iteration": (trace.get("run") or {}).get("iteration", 0),
        "final_status": (trace.get("run") or {}).get("final_status"),
    })
    return result


# ---------------------------------------------------------- Summary + OQI


def compute_summary(rows: list[dict[str, Any]]) -> dict[str, Any]:
    def avg(key_path: list[str]) -> float:
        vals = []
        for r in rows:
            cur: Any = r
            for k in key_path:
                cur = cur.get(k) if isinstance(cur, dict) else None
                if cur is None:
                    break
            if isinstance(cur, (int, float)):
                vals.append(float(cur))
        return sum(vals) / len(vals) if vals else 0.0

    def pct(vals: list[float]) -> dict[str, float]:
        if not vals:
            return {"p50": 0, "p95": 0, "p99": 0}
        s = sorted(vals)
        def q(p): return s[min(len(s) - 1, int(p * len(s)))]
        return {"p50": q(0.5), "p95": q(0.95), "p99": q(0.99)}

    latencies = [r["perf"]["latency"].get("total_ms", 0) for r in rows if r.get("perf")]
    thermal_total = sum(r["perf"]["thermal_events"] for r in rows if r.get("perf"))
    mem_peaks = [r["perf"]["peak_mem_mb"] for r in rows if r.get("perf")]
    budget_hits = [r["perf"].get("latency_ok") for r in rows
                   if r.get("perf") and r["perf"].get("latency_ok") is not None]
    budget_hit_rate = (sum(1 for ok in budget_hits if ok) / len(budget_hits)
                       if budget_hits else 0.0)

    by_tier: dict[str, list[float]] = {}
    for r in rows:
        by_tier.setdefault(r.get("complexity", "unknown"), []).append(r.get("tsr", 0.0))
    tier_stats = {k: {"n": len(v), "rate": sum(v) / len(v)} for k, v in by_tier.items()}

    tsr = avg(["tsr"])
    plan_validity = avg(["scores", "plan_validity"])
    tool_correctness = avg(["scores", "tool_correctness"])
    step_order = avg(["scores", "step_order"])
    refusal = avg(["scores", "refusal_accuracy"])
    rubber_stamp_ok = avg(["scores", "evaluator_rubber_stamp_ok"])
    replan = avg(["scores", "replan_convergence"])

    # OQI weights (sum=1.0). step_order carved out of tool_correctness' old 0.15
    # share since the two measure related aspects of planner quality — set match
    # vs sequence fidelity — and inflating total weight would break comparisons
    # against pre-trajectory runs on TSR-identical workloads.
    oqi = (
        0.40 * tsr
        + 0.10 * tool_correctness
        + 0.05 * step_order
        + 0.10 * refusal
        + 0.15 * rubber_stamp_ok
        + 0.10 * plan_validity
        + 0.10 * replan
    )

    return {
        "n_tasks": len(rows),
        "tsr": round(tsr, 3),
        "oqi": round(oqi, 3),
        "subsystem": {
            "planner_plan_validity": round(plan_validity, 3),
            "planner_tool_correctness": round(tool_correctness, 3),
            "planner_step_order": round(step_order, 3),
            "planner_refusal_accuracy": round(refusal, 3),
            "evaluator_non_rubber_stamp": round(rubber_stamp_ok, 3),
            "replan_convergence": round(replan, 3),
        },
        "perf": {
            "latency_ms": pct(latencies),
            "thermal_throttle_events": thermal_total,
            "peak_mem_mb": (max(mem_peaks) if mem_peaks else 0),
            "latency_budget_hit_rate": round(budget_hit_rate, 3),
        },
        "by_complexity": tier_stats,
    }


def render_report_md(run_label: str, summary: dict[str, Any], rows: list[dict[str, Any]]) -> str:
    lines = [
        f"# Eval Run: {run_label}",
        "",
        f"**Tasks:** {summary['n_tasks']}  "
        f"**TSR:** {summary['tsr']:.1%}  "
        f"**OQI:** {summary['oqi']:.2f}",
        "",
        "## Subsystem scores",
        "",
        "| Subsystem | Score |",
        "|---|---|",
    ]
    for k, v in summary["subsystem"].items():
        lines.append(f"| {k} | {v:.2f} |")
    lines += ["", "## Performance", ""]
    lat = summary["perf"]["latency_ms"]
    lines += [
        f"- Latency p50: {lat['p50']} ms",
        f"- Latency p95: {lat['p95']} ms",
        f"- Latency budget hit rate: {summary['perf'].get('latency_budget_hit_rate', 0):.1%}",
        f"- Thermal throttle events: {summary['perf']['thermal_throttle_events']}",
        f"- Peak memory: {summary['perf']['peak_mem_mb']} MB",
        "",
        "## By complexity",
        "",
        "| Tier | N | Pass rate |",
        "|---|---|---|",
    ]
    for tier, st in summary["by_complexity"].items():
        lines.append(f"| {tier} | {st['n']} | {st['rate']:.1%} |")
    lines += ["", "## Failures", ""]
    failures = [r for r in rows if r.get("tsr", 0) < 1.0]
    if not failures:
        lines.append("_none_")
    else:
        for r in failures:
            head = f"- **{r['task_id']}** ({r.get('complexity')})"
            err = r.get("error")
            if err:
                head += f" — **{err}**"
            lines.append(head)
            sv = r.get("state_verifier") or {}
            if sv.get("detail"):
                lines.append(f"    - state: {sv['detail']}")
            details = r.get("details") or {}
            if details.get("tool_correctness"):
                lines.append(f"    - tool: {details['tool_correctness']}")
            fi = r.get("failure_info") or {}
            fs = fi.get("failed_step")
            if fs:
                skill = fs.get("skill") or "?"
                status = fs.get("status") or "?"
                bits = [f"failed step: {fs.get('id')} ({skill}) — {status}"]
                if fs.get("error"):
                    bits.append(f"error: {fs['error']}")
                if fs.get("description"):
                    bits.append(f"desc: {fs['description']}")
                lines.append(f"    - {'; '.join(bits)}")
            if fi.get("eval_assessment"):
                lines.append(f"    - evaluator: {fi['eval_assessment']}")
            if fi.get("eval_missing"):
                lines.append(f"    - missing: {fi['eval_missing']}")
            if fi.get("eval_failed_criteria"):
                lines.append(f"    - failed criteria: {fi['eval_failed_criteria']}")
    # Budget busts are reported separately so the signal isn't lost when
    # latency enforcement is off (the default).
    busts = [
        r for r in rows
        if r.get("perf") and r["perf"].get("latency_ok") is False
    ]
    lines += ["", "## Latency budget busts", ""]
    if not busts:
        lines.append("_none_")
    else:
        for r in busts:
            lat = r["perf"]["latency"].get("total_ms", 0)
            budget = r["perf"].get("budget_ms", 0)
            passed = "pass" if r.get("tsr", 0) >= 1.0 else "fail"
            lines.append(
                f"- **{r['task_id']}**: {lat} ms vs {budget} ms budget "
                f"(+{r['perf'].get('latency_overshoot_ms', 0)} ms, task {passed})"
            )
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------- Main


def run_one(
    adb: list[str],
    task: dict[str, Any],
    out_dir: Path,
    enforce_latency_budget: bool = False,
) -> dict[str, Any]:
    task_id = task["id"]
    if task.get("turns"):
        print(f"\n[{task_id}] multi-turn — skipped (runtime not yet supported)")
        return _failure_row(
            {**task, "prompt": "(multi-turn)"},
            "skip_multi_turn",
            "multi-turn runtime not yet supported (schema-only encoding)",
        )
    print(f"\n[{task_id}] {task['prompt']}")
    timeout = int(task.get("timeout_s", 180))

    for cmd in (task.get("setup") or []):
        print(f"  setup: {cmd}")
        adb_shell(adb, cmd, timeout=30)

    # Use the task id as run_id so traces are easy to match.
    run_id = task_id
    remove_trace_if_exists(adb, run_id)

    code, out = start_eval(adb, task["prompt"], run_id)
    if code != 0:
        print(f"  am start failed: {out.strip()}")
        return _failure_row(task, "am_start_failed", out.strip()[:200])

    if not wait_for_trace(adb, run_id, timeout_s=timeout):
        return _failure_row(task, "no_trace_within_timeout", "timeout")

    local_trace = out_dir / "traces" / f"{task_id}.jsonl"
    if not pull_trace(adb, run_id, local_trace):
        return _failure_row(task, "pull_failed", "pull failed")
    trace = parse_trace(local_trace)

    run = trace.get("run") or {}
    extras = run.get("extras") or {}
    reason = extras.get("eval_failure_reason")
    if reason:
        print(f"  eval failed: {reason}")
        return _failure_row(task, f"eval_failure:{reason}", reason)

    row = score_task(task, trace, adb, enforce_latency_budget=enforce_latency_budget)

    for cmd in (task.get("teardown") or []):
        adb_shell(adb, cmd, timeout=30)

    print(f"  TSR={row['tsr']:.0f}  tool={row['scores']['tool_correctness']:.2f}  "
          f"state={row['state_verifier']['detail']}")
    return row


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", default="datasets/v1_basic.jsonl",
                    help="Path to JSONL dataset (relative to test/eval/ or absolute)")
    ap.add_argument("--task", help="Run only this task id")
    ap.add_argument("--label", default=None, help="Run label (default: current git branch)")
    ap.add_argument("--serial", default=None, help="ADB device serial")
    ap.add_argument("--out", default="runs", help="Output dir (under test/eval/)")
    ap.add_argument("--skip-preflight", action="store_true",
                    help="Skip pm grant preflight (use if permissions are managed externally)")
    ap.add_argument("--enforce-latency-budget", action="store_true",
                    help="Count a task that exceeds its per-task budget_ms as TSR=0 "
                         "(default: budget bust is informational only)")
    # Thermal throttling: memory notes ~30min of continuous Gemma inference
    # degrades SoC throughput. Two levers here:
    #   --cooldown-every / --cooldown-s: idle-sleep between batches so the SoC cools.
    #   --thermal-stretch-after / --thermal-stretch-mult: give later tasks more
    #     wall-clock time because throttled inference is slower per token even
    #     when the orchestration is identical.
    ap.add_argument("--cooldown-every", type=int, default=0,
                    help="Sleep between every N tasks to let the SoC cool "
                         "(default 0 = no cooldown). Typical: 5.")
    ap.add_argument("--cooldown-s", type=int, default=45,
                    help="Seconds to sleep at each cooldown point (default 45)")
    ap.add_argument("--thermal-stretch-after", type=int, default=0,
                    help="Task index (1-based) past which timeout_s/budget_ms are "
                         "multiplied by --thermal-stretch-mult (default 0 = off). "
                         "Typical: 5.")
    ap.add_argument("--thermal-stretch-mult", type=float, default=1.5,
                    help="Multiplier applied to timeout/budget past "
                         "--thermal-stretch-after (default 1.5)")
    args = ap.parse_args()

    adb = adb_base(args.serial)
    ensure_device(adb)
    ensure_trace_dir(adb)
    if not args.skip_preflight:
        preflight_permissions(adb)

    dataset_path = Path(args.dataset)
    if not dataset_path.is_absolute():
        dataset_path = ROOT / dataset_path
    if not dataset_path.exists():
        print(f"ERROR: dataset not found: {dataset_path}", file=sys.stderr)
        return 2

    tasks: list[dict[str, Any]] = []
    with dataset_path.open() as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            tasks.append(json.loads(line))
    if args.task:
        tasks = [t for t in tasks if t["id"] == args.task]
        if not tasks:
            print(f"ERROR: task '{args.task}' not in dataset", file=sys.stderr)
            return 2

    label = args.label
    if not label:
        code, out = sh(["git", "-C", str(ROOT.parent.parent), "rev-parse", "--abbrev-ref", "HEAD"])
        label = (out.strip() or "unknown") if code == 0 else "unknown"
    ts = _dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_dir = ROOT / args.out / f"{label}-{ts}"
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Running {len(tasks)} task(s) → {out_dir}")
    rows: list[dict[str, Any]] = []
    for idx, task in enumerate(tasks, start=1):
        # Stretch timeout + budget for tasks past the thermal threshold so slower
        # throttled inference doesn't look like an orchestration regression.
        if args.thermal_stretch_after and idx > args.thermal_stretch_after:
            base_to = int(task.get("timeout_s", 180))
            base_bd = int(task.get("budget_ms", base_to * 500))
            task = {
                **task,
                "timeout_s": int(base_to * args.thermal_stretch_mult),
                "budget_ms": int(base_bd * args.thermal_stretch_mult),
            }
        row = run_one(adb, task, out_dir, enforce_latency_budget=args.enforce_latency_budget)
        rows.append(row)
        (out_dir / "results.partial.json").write_text(json.dumps(rows, indent=2))
        # Cooldown between batches. Skip after the final task — no point sleeping
        # if we're done. Also skip if the task failed to start (am_start_failed),
        # since the device wasn't actually working.
        if (
            args.cooldown_every
            and args.cooldown_every > 0
            and idx < len(tasks)
            and idx % args.cooldown_every == 0
        ):
            print(f"  cooldown: sleeping {args.cooldown_s}s after task #{idx}")
            time.sleep(args.cooldown_s)

    summary = compute_summary(rows)
    results = {
        "label": label,
        "timestamp": ts,
        "dataset": str(dataset_path.relative_to(ROOT) if dataset_path.is_relative_to(ROOT) else dataset_path),
        "summary": summary,
        "rows": rows,
    }
    (out_dir / "results.json").write_text(json.dumps(results, indent=2))
    (out_dir / "report.md").write_text(render_report_md(f"{label} @ {ts}", summary, rows))
    partial = out_dir / "results.partial.json"
    if partial.exists():
        partial.unlink()

    print("\n" + "=" * 50)
    print(f"TSR {summary['tsr']:.1%}   OQI {summary['oqi']:.2f}")
    print(f"Report: {out_dir / 'report.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
