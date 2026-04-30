#!/usr/bin/env python3
"""EdgeCat iOS eval harness.

Mirrors `android-app/test/eval/run.py` but drives an iPhone simulator via
`xcrun simctl` instead of `adb`. Schema-compatible with the Android scorers
(see `scorers/{structural,state,perf}.py`) so a v1_basic run on iOS produces
the same OQI-shaped output as Android.

Quickstart:
    # 1) boot a sim (one-time)
    xcrun simctl boot 80A09B97-...

    # 2) install the app (built from xcodegen + xcodebuild)
    xcrun simctl install 80A09B97-... .../EdgeCat.app

    # 3) pre-flight permissions (one-time per sim)
    test/eval/scripts/preflight.sh 80A09B97-...

    # 4) run a dataset
    python test/eval/run.py \\
        --dataset datasets/v1_basic.jsonl \\
        --label main \\
        --udid 80A09B97-... \\
        --bundle-id com.edgecat.app \\
        --model gemma-4-E2B-it.litertlm \\
        --model-source ~/Models/gemma-4-E2B-it.litertlm

    # 5) inspect
    open test/eval/runs/main-*/report.md
"""
from __future__ import annotations
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

# `simctl` lives under the full Xcode developer dir, not the Command Line
# Tools dir. Set DEVELOPER_DIR if not already so `xcrun simctl` resolves.
os.environ.setdefault("DEVELOPER_DIR",
                      "/Applications/Xcode.app/Contents/Developer")

# Ensure we can `import scorers.*` regardless of cwd.
ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from scorers import structural, perf, state  # noqa: E402

DEFAULT_BUNDLE_ID = "com.edgecat.app"
DEFAULT_TIMEOUT_S = 180
PRIVACY_SERVICES = [
    "calendar", "contacts", "photos-add", "photos",
    "location", "microphone", "camera", "reminders", "motion",
]


# ---------------------------------------------------------------- utilities

def sh(cmd: list[str], timeout: int = 30) -> tuple[int, str]:
    """Run a subprocess, returning (exit_code, combined_stdout_stderr)."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return result.returncode, (result.stdout or "") + (result.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "timeout"
    except Exception as exc:  # noqa: BLE001
        return 1, f"error: {exc}"


# ---------------------------------------------------------------- device control

def ensure_simulator_booted(udid: str) -> None:
    code, out = sh(["xcrun", "simctl", "list", "devices", "-j"], timeout=10)
    if code != 0:
        raise SystemExit(f"simctl list failed: {out}")
    info = json.loads(out)
    for runtime in info.get("devices", {}).values():
        for dev in runtime:
            if dev.get("udid") == udid:
                if dev.get("state") != "Booted":
                    print(f"[runner] booting {udid}…")
                    sh(["xcrun", "simctl", "boot", udid], timeout=60)
                    sh(["xcrun", "simctl", "bootstatus", udid], timeout=120)
                return
    raise SystemExit(f"simulator UDID not found: {udid}")


def app_data_container(udid: str, bundle_id: str) -> Path:
    """Path to the app's data sandbox on the simulator."""
    code, out = sh(["xcrun", "simctl", "get_app_container", udid, bundle_id, "data"], timeout=10)
    if code != 0:
        raise SystemExit(f"get_app_container failed (is the app installed?): {out}")
    return Path(out.strip())


def preflight_permissions(udid: str, bundle_id: str) -> None:
    """Pre-grant the privacy services the eval skills need + push a
    deterministic GPS fix into the simulator + seed a photo into the
    library. Same idea as Android's `pm grant` block in run.py, plus a
    `simctl location set` so CoreLocation has something to deliver to
    `requestLocation`, plus a `simctl addmedia` so `state-photo-recent-001`
    has a present-day asset to find.
    """
    for service in PRIVACY_SERVICES:
        sh(["xcrun", "simctl", "privacy", udid, "grant", service, bundle_id], timeout=10)
    # iOS 17+ added a second readWrite consent gate to the Photos
    # framework that simctl's `privacy grant` doesn't update: the rows
    # it writes carry auth_version=1, but the framework only honors
    # readWrite from auth_version>=2 entries — so the app sees `.denied`
    # despite TCC saying "allowed". Bump it directly in TCC.db once.
    tcc_db = (Path.home() / "Library/Developer/CoreSimulator/Devices"
              / udid / "data/Library/TCC/TCC.db")
    if tcc_db.exists():
        sh(["sqlite3", str(tcc_db),
            f"UPDATE access SET auth_version=2 "
            f"WHERE client='{bundle_id}' "
            f"AND service IN ('kTCCServicePhotos','kTCCServicePhotosAdd');"],
           timeout=10)
    # Apple Park (Cupertino) — matches `directions-walk-001` notes that
    # expect a coffee shop near the sim's default location.
    sh(["xcrun", "simctl", "location", udid, "set", "37.3349,-122.0090"], timeout=10)
    # Seed a fresh-dated photo so `state-photo-recent-001` (verifier
    # date_offset=0 = today) has something to find. The PHAsset's
    # `creationDate` comes from the file's EXIF metadata if present,
    # otherwise from the file system. Macos bundled wallpapers carry an
    # old DateTimeOriginal in EXIF and so won't match "today" — we take
    # a screenshot of the booted sim instead, which writes a PNG whose
    # creationDate the Photos framework treats as "now".
    snap = Path(f"/tmp/mc-eval-seed-{udid[:8]}.png")
    code, _ = sh(["xcrun", "simctl", "io", udid, "screenshot", str(snap)], timeout=15)
    if code == 0 and snap.exists():
        sh(["xcrun", "simctl", "addmedia", udid, str(snap)], timeout=15)
    # QR-code seed so `qr-scan-001` ("Find the photo named test_qr_claude")
    # has a scannable image to find. Payload "Claude Code" matches the
    # task's verifier regex `(?i)claude.?code`. We rely on `qrencode`
    # being on PATH (homebrew default); silently skip if absent.
    qr_path = Path(f"/tmp/test_qr_claude.png")
    if shutil.which("qrencode"):
        sh(["qrencode", "-o", str(qr_path), "Claude Code", "-s", "8", "-m", "4"], timeout=10)
        if qr_path.exists():
            sh(["xcrun", "simctl", "addmedia", udid, str(qr_path)], timeout=15)


def push_model(udid: str, bundle_id: str, model_source: Path, model_filename: str) -> None:
    """Copy the .litertlm model into the app's Documents/Models. Skips if
    a same-size file is already there (these are 2-4GB)."""
    container = app_data_container(udid, bundle_id)
    models_dir = container / "Documents" / "Models"
    models_dir.mkdir(parents=True, exist_ok=True)
    dest = models_dir / model_filename
    src = model_source.expanduser().resolve()
    if dest.exists() and dest.stat().st_size == src.stat().st_size:
        print(f"[runner] model already in sandbox at {dest} — skipping copy")
        return
    print(f"[runner] copying {src} → {dest} …")
    shutil.copy2(src, dest)


def trace_path(udid: str, bundle_id: str, run_id: str) -> Path:
    return app_data_container(udid, bundle_id) / "Documents" / "edgecat-traces" / f"{run_id}.jsonl"


def remove_trace_if_exists(udid: str, bundle_id: str, run_id: str) -> None:
    p = trace_path(udid, bundle_id, run_id)
    if p.exists():
        p.unlink()


def terminate_app(udid: str, bundle_id: str) -> None:
    sh(["xcrun", "simctl", "terminate", udid, bundle_id], timeout=15)


def wait_for_app_dead(udid: str, bundle_id: str, timeout_s: int = 15) -> None:
    """Mirrors Android's pidof-poll loop. Best-effort — simctl doesn't
    expose a clean process-list, so we just sleep a short backoff after
    `terminate`. The app needs ~1-3s to release Metal + LiteRT-LM
    resources before the next launch."""
    time.sleep(min(timeout_s, 3))


def launch_app(udid: str, bundle_id: str) -> None:
    """Launch with EDGECAT_EVAL_MODE=1 so EdgeCatApp renders the
    headless EvalRunnerView instead of AppRouter.

    `simctl launch` doesn't take `--setenv` directly — it inherits any
    `SIMCTL_CHILD_<VARNAME>` from the calling environment and passes them
    into the launched app stripped of the `SIMCTL_CHILD_` prefix.
    """
    env = {**os.environ, "SIMCTL_CHILD_EDGECAT_EVAL_MODE": "1"}
    try:
        result = subprocess.run(
            ["xcrun", "simctl", "launch", udid, bundle_id],
            capture_output=True, text=True, timeout=20, env=env)
    except subprocess.TimeoutExpired:
        raise SystemExit("simctl launch timed out")
    if result.returncode != 0:
        raise SystemExit(
            f"simctl launch failed: {(result.stdout or '') + (result.stderr or '')}")


def open_eval_url(udid: str, prompt: str, run_id: str, model_filename: str | None,
                  agentic: bool) -> None:
    """Send `edgecat://eval?...` to the app. Matches the URL contract
    in `EvalEntryPoint.swift`."""
    from urllib.parse import quote
    url = (f"edgecat://eval?prompt={quote(prompt, safe='')}"
           f"&runId={quote(run_id, safe='')}")
    if model_filename:
        url += f"&model={quote(model_filename, safe='')}"
    if agentic:
        url += "&agentic=1"
    code, out = sh(["xcrun", "simctl", "openurl", udid, url], timeout=15)
    if code != 0:
        raise SystemExit(f"simctl openurl failed: {out}")


def open_verify_url(udid: str, run_id: str, kind: str, params: dict[str, Any]) -> None:
    """Send `edgecat://verify?...` so the in-app `StateVerifiers` can
    query an iOS framework (EventKit, EKReminder, UNUserNotificationCenter,
    Contacts, Photos, HealthKit, …) and emit a `kind=verify` span the
    scorer reads. Mirrors `open_eval_url` shape."""
    from urllib.parse import quote
    qs = [f"runId={quote(run_id, safe='')}", f"kind={quote(kind, safe='')}"]
    for k, v in params.items():
        qs.append(f"{quote(str(k), safe='')}={quote(str(v), safe='')}")
    url = "edgecat://verify?" + "&".join(qs)
    code, out = sh(["xcrun", "simctl", "openurl", udid, url], timeout=15)
    if code != 0:
        raise SystemExit(f"simctl openurl (verify) failed: {out}")


def wait_for_verify(udid: str, bundle_id: str, run_id: str,
                    kind: str, timeout_s: int = 30) -> bool:
    """Wait for `kind=verify, name=complete` sentinel appended to the
    same `<run_id>.jsonl` trace by `StateVerifiers.runAndEmit`. The
    matching `kind=verify, name=<kind>` span is what the scorer reads."""
    path = trace_path(udid, bundle_id, run_id)
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if path.exists():
            try:
                content = path.read_text()
            except OSError:
                content = ""
            for line in content.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                span = obj.get("span") or {}
                if obj.get("type") == "span" \
                   and span.get("kind") == "verify" \
                   and span.get("name") == "complete":
                    time.sleep(0.3)  # let the trailing write flush
                    return True
        time.sleep(1)
    return False


def wait_for_trace(udid: str, bundle_id: str, run_id: str, timeout_s: int) -> bool:
    """Wait for the eval-complete sentinel line written by
    `EvalEntryPoint.run` after the run summary. Pure file-size-stability
    polling is a trap: model loading takes 15-30s during which only the
    early `eval-start` line is on disk, and the file looks "stable" to
    a naive poller after a few seconds. The sentinel is the only safe
    signal."""
    path = trace_path(udid, bundle_id, run_id)
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if path.exists():
            try:
                content = path.read_text()
            except OSError:
                content = ""
            for line in content.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                # Sentinel: `event(kind:"eval", name:"complete", …)` —
                # always the last line EvalEntryPoint writes (after the
                # run summary). Catches both ok and error paths.
                span = obj.get("span") or {}
                if obj.get("type") == "span" \
                   and span.get("kind") == "eval" \
                   and span.get("name") == "complete":
                    # Settle for one more poll so any in-flight write
                    # to the same file completes.
                    time.sleep(0.5)
                    return True
        time.sleep(2)
    return False


def pull_trace(udid: str, bundle_id: str, run_id: str, local_dir: Path) -> Path | None:
    src = trace_path(udid, bundle_id, run_id)
    if not src.exists():
        return None
    local_dir.mkdir(parents=True, exist_ok=True)
    dest = local_dir / f"{run_id}.jsonl"
    shutil.copy2(src, dest)
    return dest


# ---------------------------------------------------------------- trace parsing

def parse_trace(path: Path) -> dict[str, Any]:
    """Parse a JSONL trace into {run: {...}, spans: [{...}]}."""
    run = None
    spans: list[dict[str, Any]] = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("type") == "run":
            run = obj.get("run", {})
        elif obj.get("type") == "span":
            spans.append(obj.get("span", {}))
    return {"run": run or {}, "spans": spans}


# ---------------------------------------------------------------- scoring


def extract_failure_info(trace: dict[str, Any]) -> dict[str, Any]:
    run = trace.get("run", {})
    failed_step = None
    for step_id, result in (run.get("step_results") or {}).items():
        if result.get("status") in ("FAILED", "SKIPPED"):
            failed_step = {"id": step_id, **result}
            break
    eval_result = run.get("evaluation") or {}
    return {
        "failed_step": failed_step,
        "eval_assessment": eval_result.get("assessment"),
        "eval_missing": eval_result.get("missing_items") or [],
        "eval_failed_criteria": eval_result.get("failed_criteria") or [],
    }


def score_task(task: dict[str, Any], trace: dict[str, Any], adb: list[str] | None) -> dict[str, Any]:
    run = trace.get("run", {})
    spans = trace.get("spans", [])
    final_status = run.get("final_status", "incomplete")
    expected = task.get("expected_skills") or []

    # State verifier first — its outcome feeds into rubber-stamp scoring.
    verifier_spec = task.get("verifier") or {"type": "none"}
    state_passed, state_detail = state.run_verifier(adb or [], trace, verifier_spec)

    # Structural — every scorer takes the full trace dict, returns
    # (score, detail). We keep the score; details land in failure_info.
    pv_score, _ = structural.plan_validity(trace)
    tc_score, _ = structural.tool_correctness(trace, expected)
    so_score, _ = structural.step_order_lcs(trace, expected)
    ra_score, _ = structural.refusal_accuracy(trace, task.get("should_refuse", False))
    rc_score, _ = structural.replan_convergence(trace)
    rs_score, _ = structural.evaluator_rubber_stamp(trace, state_passed)

    scores = {
        "plan_validity": pv_score,
        "tool_correctness": tc_score,
        "step_order": so_score,
        "refusal_accuracy": ra_score,
        "replan_convergence": rc_score,
        "evaluator_rubber_stamp_ok": rs_score,
    }

    # TSR: state verifier wins; if it returned None (skipped) fall back
    # to final_status. Mirrors Android's `tsr_from_state_or_eval`.
    if state_passed is True:
        tsr = 1.0
    elif state_passed is False:
        tsr = 0.0
    else:
        tsr = 1.0 if final_status == "ok" else 0.0

    # Performance — compose individual scorers.
    latency = perf.latency_stats(trace)
    thermal_count, _ = perf.thermal_events(trace)
    peak_mem = perf.peak_memory_mb(trace)
    tps = perf.tokens_per_sec(trace)
    budget_ms = task.get("budget_ms") or task.get("timeout_s", DEFAULT_TIMEOUT_S) * 500
    total_ms = latency.get("total_ms") or 0
    latency_ok = total_ms <= budget_ms if total_ms else False
    perf_block = {
        "latency": latency,
        "thermal_events": thermal_count,
        "peak_mem_mb": peak_mem,
        "tokens_per_sec": tps,
        "budget_ms": budget_ms,
        "latency_ok": latency_ok,
        "latency_overshoot_ms": max(0, total_ms - budget_ms),
    }

    return {
        "task_id": task["id"],
        "prompt": task.get("prompt", ""),
        "category": task.get("category", "other"),
        "complexity": task.get("complexity", "single-skill"),
        "tsr": tsr,
        "scores": scores,
        "state_verifier": {
            "type": verifier_spec.get("type"),
            "passed": state_passed,
            "detail": state_detail,
        },
        "perf": perf_block,
        "failure_info": extract_failure_info(trace) if tsr < 1.0 else None,
        "iteration": run.get("iteration", 0),
        "final_status": final_status,
    }


def compute_summary(rows: list[dict[str, Any]], skipped: list[dict[str, Any]]) -> dict[str, Any]:
    n = len(rows)
    if n == 0:
        return {"n_tasks": 0, "n_skipped": len(skipped),
                "tsr": 0.0, "oqi": 0.0,
                "subsystem": {}, "perf": {}, "by_complexity": {}}

    avg = lambda key: sum(r["scores"].get(key, 0.0) for r in rows) / n
    tsr = sum(r["tsr"] for r in rows) / n
    oqi = (
        0.40 * tsr
        + 0.10 * avg("tool_correctness")
        + 0.05 * avg("step_order")
        + 0.10 * avg("refusal_accuracy")
        + 0.15 * avg("evaluator_rubber_stamp_ok")
        + 0.10 * avg("plan_validity")
        + 0.10 * avg("replan_convergence")
    )

    # Latency percentiles + budget hit rate.
    latencies = [r["perf"]["latency"]["total_ms"] for r in rows
                 if r["perf"]["latency"].get("total_ms")]
    latencies.sort()
    def pct(p):
        if not latencies: return 0
        idx = max(0, min(len(latencies) - 1, int(round((p / 100.0) * (len(latencies) - 1)))))
        return latencies[idx]
    budget_ok = sum(1 for r in rows if r["perf"].get("latency_ok"))
    thermal_evts = sum(r["perf"].get("thermal_events", 0) for r in rows)
    peak_mem = max((r["perf"].get("peak_mem_mb") or 0) for r in rows) if rows else 0

    by_complexity: dict[str, dict[str, float]] = {}
    for r in rows:
        c = r["complexity"]
        b = by_complexity.setdefault(c, {"n": 0, "passed": 0})
        b["n"] += 1
        if r["tsr"] >= 1.0:
            b["passed"] += 1
    by_complexity = {c: {"n": v["n"], "rate": v["passed"] / v["n"] if v["n"] else 0.0}
                     for c, v in by_complexity.items()}

    return {
        "n_tasks": n,
        "n_skipped": len(skipped),
        "tsr": tsr,
        "oqi": oqi,
        "subsystem": {
            "plan_validity": avg("plan_validity"),
            "tool_correctness": avg("tool_correctness"),
            "step_order": avg("step_order"),
            "refusal_accuracy": avg("refusal_accuracy"),
            "replan_convergence": avg("replan_convergence"),
            "evaluator_rubber_stamp_ok": avg("evaluator_rubber_stamp_ok"),
        },
        "perf": {
            "latency_ms": {"p50": pct(50), "p95": pct(95), "p99": pct(99)},
            "thermal_throttle_events": thermal_evts,
            "peak_mem_mb": peak_mem,
            "latency_budget_hit_rate": budget_ok / n if n else 0.0,
        },
        "by_complexity": by_complexity,
    }


# ---------------------------------------------------------------- report

def render_report_md(label: str, summary: dict[str, Any],
                     rows: list[dict[str, Any]], skipped: list[dict[str, Any]]) -> str:
    out: list[str] = []
    out.append(f"# EdgeCat iOS eval — {label}")
    out.append("")
    out.append(f"- **TSR:** {summary['tsr'] * 100:.1f}%  ({summary['n_tasks']} tasks)")
    out.append(f"- **OQI:** {summary['oqi']:.3f}")
    if summary["n_skipped"]:
        out.append(f"- **Skipped (iOS-incompatible):** {summary['n_skipped']}")
    out.append("")
    out.append("## Subsystem")
    out.append("")
    out.append("| Score | Value |")
    out.append("|---|---|")
    for k, v in summary["subsystem"].items():
        out.append(f"| {k} | {v:.3f} |")
    out.append("")
    out.append("## Performance")
    out.append("")
    p = summary["perf"]
    out.append(f"- p50/p95/p99 latency: {p['latency_ms']['p50']} / {p['latency_ms']['p95']} / {p['latency_ms']['p99']} ms")
    out.append(f"- latency budget hit rate: {p['latency_budget_hit_rate'] * 100:.1f}%")
    out.append(f"- thermal events: {p['thermal_throttle_events']}")
    out.append(f"- peak resident memory: {p['peak_mem_mb']} MB")
    out.append("")
    out.append("## By complexity")
    out.append("")
    for c, v in summary["by_complexity"].items():
        out.append(f"- {c}: {v['rate'] * 100:.1f}% ({v['n']} tasks)")
    out.append("")
    failures = [r for r in rows if r["tsr"] < 1.0]
    if failures:
        out.append("## Failures")
        out.append("")
        for r in failures:
            fi = r.get("failure_info") or {}
            out.append(f"### {r['task_id']} — {r['prompt'][:80]}")
            out.append(f"- final_status: `{r['final_status']}`")
            if fi.get("failed_step"):
                fs = fi["failed_step"]
                out.append(f"- failed step: `{fs.get('id')}` — {fs.get('error') or fs.get('output', '')[:100]}")
            if fi.get("eval_assessment"):
                out.append(f"- eval: {fi['eval_assessment']}")
            out.append("")
    busts = [r for r in rows if not r["perf"].get("latency_ok") and r["tsr"] >= 1.0]
    if busts:
        out.append("## Latency budget busts (TSR=1)")
        out.append("")
        for r in busts:
            out.append(f"- {r['task_id']}: {r['perf']['latency']['total_ms']} ms vs budget {r['perf'].get('budget_ms')} ms")
        out.append("")
    if skipped:
        out.append("## Skipped tasks (iOS-incompatible)")
        out.append("")
        for s in skipped:
            out.append(f"- `{s['id']}` — {s.get('reason', 'platform mismatch')}")
        out.append("")
    return "\n".join(out)


# ---------------------------------------------------------------- per-task driver

def run_one(args: argparse.Namespace, task: dict[str, Any], traces_dir: Path) -> dict[str, Any]:
    udid = args.udid
    bundle = args.bundle_id
    run_id = task["id"]
    timeout_s = int(task.get("timeout_s") or DEFAULT_TIMEOUT_S)
    if task.get("skip_on_ios"):
        return {"id": run_id, "skipped": True,
                "reason": task.get("skip_on_ios_reason", "skip_on_ios")}

    print(f"[runner] {run_id} — {task.get('prompt', '')[:80]}")

    terminate_app(udid, bundle)
    wait_for_app_dead(udid, bundle)
    remove_trace_if_exists(udid, bundle, run_id)
    launch_app(udid, bundle)
    # Push a fresh GPS fix into the simulator AFTER the app launches —
    # `simctl location set` only delivers to running CoreLocation
    # consumers, so the location reset that's done at preflight gets
    # forgotten by the time CLLocationManager.requestLocation fires
    # 30+s later. Apple Park (Cupertino) — matches `directions-walk-001`
    # task notes about a coffee-shop neighbor.
    sh(["xcrun", "simctl", "location", udid, "set", "37.3349,-122.0090"], timeout=10)
    open_eval_url(udid, prompt=task["prompt"], run_id=run_id,
                  model_filename=args.model, agentic=not task.get("no_agentic", False))
    if not wait_for_trace(udid, bundle, run_id, timeout_s):
        # Pull whatever exists — incomplete trace is still useful for triage.
        local = pull_trace(udid, bundle, run_id, traces_dir)
        return {"task": task, "trace_path": str(local) if local else None,
                "timeout": True}

    # Run the in-app state verifier (if applicable) before pulling the
    # trace, so the verify span ends up in the same file the scorer
    # reads. Only fires for `state` verifier tasks; `output_regex` and
    # `llm_judge` are trace-only and don't need an iOS-side query.
    verifier = task.get("verifier") or {}
    if verifier.get("type") == "state":
        kind = verifier.get("check") or ""
        params = verifier.get("params") or {}
        try:
            open_verify_url(udid, run_id, kind, params)
            wait_for_verify(udid, bundle, run_id, kind)
        except SystemExit as e:
            # Don't kill the whole batch on a single verify failure —
            # the scorer will surface "no verify span" if we missed it.
            print(f"[runner]   verify error: {e}")

    local = pull_trace(udid, bundle, run_id, traces_dir)
    return {"task": task, "trace_path": str(local) if local else None}


# ---------------------------------------------------------------- entry point

def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--dataset", required=True, help="JSONL dataset")
    p.add_argument("--label", required=True, help="run label (becomes dirname)")
    p.add_argument("--udid", required=True, help="simulator UDID")
    p.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    p.add_argument("--model", help="model filename inside Documents/Models",
                   default=None)
    p.add_argument("--model-source", help="local path to .litertlm to push", default=None)
    p.add_argument("--cooldown-every", type=int, default=0,
                   help="sleep --cooldown-s every N tasks (0=off)")
    p.add_argument("--cooldown-s", type=int, default=45)
    p.add_argument("--thermal-stretch-after", type=int, default=0)
    p.add_argument("--thermal-stretch-mult", type=float, default=1.5)
    p.add_argument("--filter", default=None,
                   help="substring filter on task id (run a subset)")
    p.add_argument("--no-preflight", action="store_true",
                   help="skip simctl privacy grant pre-flight")
    p.add_argument("--no-push", action="store_true",
                   help="skip pushing the model file")
    args = p.parse_args()

    ensure_simulator_booted(args.udid)
    if not args.no_preflight:
        preflight_permissions(args.udid, args.bundle_id)
    if args.model and args.model_source and not args.no_push:
        push_model(args.udid, args.bundle_id,
                   Path(args.model_source), args.model)

    timestamp = time.strftime("%Y%m%d-%H%M%S")
    run_dir = ROOT / "runs" / f"{args.label}-{timestamp}"
    traces_dir = run_dir / "traces"
    run_dir.mkdir(parents=True, exist_ok=True)

    tasks = []
    with open(args.dataset) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            obj = json.loads(line)
            if args.filter and args.filter not in obj["id"]: continue
            tasks.append(obj)

    rows: list[dict[str, Any]] = []
    skipped: list[dict[str, Any]] = []

    for idx, task in enumerate(tasks, start=1):
        # Apply thermal stretch.
        if args.thermal_stretch_after and idx > args.thermal_stretch_after:
            task = {**task,
                    "timeout_s": int((task.get("timeout_s") or DEFAULT_TIMEOUT_S) * args.thermal_stretch_mult),
                    "budget_ms": int((task.get("budget_ms") or DEFAULT_TIMEOUT_S * 500) * args.thermal_stretch_mult)}

        result = run_one(args, task, traces_dir)
        if result.get("skipped"):
            print(f"[runner]   skipped: {result['reason']}")
            skipped.append({"id": task["id"], "reason": result["reason"]})
            continue
        if not result.get("trace_path"):
            print(f"[runner]   no trace produced (timeout={result.get('timeout', False)})")
            rows.append({"task_id": task["id"], "prompt": task.get("prompt", ""),
                         "category": task.get("category", "other"),
                         "complexity": task.get("complexity", "single-skill"),
                         "tsr": 0.0, "scores": {}, "state_verifier": {"type": None, "passed": False, "detail": "no trace"},
                         "perf": {"latency": {}, "latency_ok": False, "budget_ms": task.get("budget_ms")},
                         "failure_info": {"failed_step": None, "eval_assessment": "no trace produced",
                                          "eval_missing": [], "eval_failed_criteria": []},
                         "iteration": 0, "final_status": "incomplete"})
        else:
            trace = parse_trace(Path(result["trace_path"]))
            row = score_task(task, trace, adb=None)
            rows.append(row)

        # Save partial results after each task — Ctrl-C survives.
        partial = run_dir / "results.partial.json"
        partial.write_text(json.dumps({
            "label": args.label,
            "timestamp": timestamp,
            "dataset": args.dataset,
            "summary": compute_summary(rows, skipped),
            "rows": rows,
            "skipped": skipped,
        }, indent=2, default=str))

        if args.cooldown_every and idx % args.cooldown_every == 0 and idx < len(tasks):
            print(f"[runner] cooldown {args.cooldown_s}s")
            time.sleep(args.cooldown_s)

    summary = compute_summary(rows, skipped)
    final = {
        "label": args.label,
        "timestamp": timestamp,
        "dataset": args.dataset,
        "summary": summary,
        "rows": rows,
        "skipped": skipped,
    }
    (run_dir / "results.json").write_text(json.dumps(final, indent=2, default=str))
    (run_dir / "report.md").write_text(render_report_md(args.label, summary, rows, skipped))
    partial = run_dir / "results.partial.json"
    if partial.exists(): partial.unlink()

    print()
    print(f"[runner] TSR={summary['tsr'] * 100:.1f}%  OQI={summary['oqi']:.3f}  "
          f"({summary['n_tasks']} tasks, {summary['n_skipped']} skipped)")
    print(f"[runner] report: {run_dir / 'report.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
