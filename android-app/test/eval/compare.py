#!/usr/bin/env python3
"""A/B diff between two EdgeCat eval runs.

Usage:
    python android-app/test/eval/compare.py <baseline_run_dir> <candidate_run_dir>
    python android-app/test/eval/compare.py runs/main-20260418-090000 runs/exp-20260418-120000

Each argument is a run directory produced by run.py (must contain results.json).
Prints a markdown delta table to stdout and writes it to
<candidate>/compare-vs-<baseline_label>.md so the diff is archived alongside the run.

Exit codes:
    0  candidate ≥ baseline (no regression, OQI delta ≥ 0)
    1  candidate < baseline (OQI regressed)
    2  usage / IO error
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def load_results(run_dir: Path) -> dict[str, Any]:
    rj = run_dir / "results.json"
    if not rj.exists():
        raise FileNotFoundError(f"no results.json in {run_dir}")
    return json.loads(rj.read_text())


def delta(a: float, b: float) -> str:
    d = b - a
    sign = "+" if d > 0 else ""
    return f"{sign}{d:.3f}"


def fmt_pct(x: float) -> str:
    return f"{x:.1%}"


def rows_by_id(results: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {r["task_id"]: r for r in results.get("rows", [])}


def classify_task_delta(a: dict[str, Any], b: dict[str, Any]) -> str:
    """Return one of: regression, improvement, still_fail, still_pass, n/a."""
    at = a.get("tsr")
    bt = b.get("tsr")
    if at is None or bt is None:
        return "n/a"
    if at >= 1.0 and bt < 1.0:
        return "regression"
    if at < 1.0 and bt >= 1.0:
        return "improvement"
    if at < 1.0 and bt < 1.0:
        return "still_fail"
    return "still_pass"


def render(baseline: dict[str, Any], candidate: dict[str, Any]) -> tuple[str, float]:
    """Return (markdown, oqi_delta)."""
    bs = baseline.get("summary", {})
    cs = candidate.get("summary", {})
    bl_label = f"{baseline.get('label')} @ {baseline.get('timestamp')}"
    cd_label = f"{candidate.get('label')} @ {candidate.get('timestamp')}"

    oqi_delta = cs.get("oqi", 0) - bs.get("oqi", 0)

    lines = [
        f"# A/B: {cd_label} vs baseline {bl_label}",
        "",
        "## Headline",
        "",
        "| Metric | Baseline | Candidate | Δ |",
        "|---|---|---|---|",
        f"| TSR | {fmt_pct(bs.get('tsr', 0))} | {fmt_pct(cs.get('tsr', 0))} | {delta(bs.get('tsr', 0), cs.get('tsr', 0))} |",
        f"| OQI | {bs.get('oqi', 0):.3f} | {cs.get('oqi', 0):.3f} | {delta(bs.get('oqi', 0), cs.get('oqi', 0))} |",
        f"| N tasks | {bs.get('n_tasks', 0)} | {cs.get('n_tasks', 0)} | — |",
        "",
        "## Subsystem scores",
        "",
        "| Subsystem | Baseline | Candidate | Δ |",
        "|---|---|---|---|",
    ]
    b_sub = bs.get("subsystem", {})
    c_sub = cs.get("subsystem", {})
    all_keys = sorted(set(b_sub) | set(c_sub))
    for k in all_keys:
        lines.append(
            f"| {k} | {b_sub.get(k, 0):.2f} | {c_sub.get(k, 0):.2f} | "
            f"{delta(b_sub.get(k, 0), c_sub.get(k, 0))} |"
        )

    # Complexity tiers
    lines += ["", "## By complexity", "", "| Tier | Baseline | Candidate | Δ |", "|---|---|---|---|"]
    b_tiers = bs.get("by_complexity", {})
    c_tiers = cs.get("by_complexity", {})
    for tier in sorted(set(b_tiers) | set(c_tiers)):
        br = b_tiers.get(tier, {}).get("rate", 0)
        cr = c_tiers.get(tier, {}).get("rate", 0)
        bn = b_tiers.get(tier, {}).get("n", 0)
        cn = c_tiers.get(tier, {}).get("n", 0)
        lines.append(f"| {tier} (n={bn}→{cn}) | {fmt_pct(br)} | {fmt_pct(cr)} | {delta(br, cr)} |")

    # Perf
    b_perf = bs.get("perf", {})
    c_perf = cs.get("perf", {})
    b_lat = b_perf.get("latency_ms", {})
    c_lat = c_perf.get("latency_ms", {})
    lines += ["", "## Performance", "", "| Metric | Baseline | Candidate | Δ |", "|---|---|---|---|"]
    for pk in ("p50", "p95", "p99"):
        bv = b_lat.get(pk, 0)
        cv = c_lat.get(pk, 0)
        lines.append(f"| latency {pk} (ms) | {bv} | {cv} | {cv - bv:+d} |")
    lines.append(
        f"| thermal events | {b_perf.get('thermal_throttle_events', 0)} | "
        f"{c_perf.get('thermal_throttle_events', 0)} | "
        f"{c_perf.get('thermal_throttle_events', 0) - b_perf.get('thermal_throttle_events', 0):+d} |"
    )
    lines.append(
        f"| peak mem (MB) | {b_perf.get('peak_mem_mb', 0)} | "
        f"{c_perf.get('peak_mem_mb', 0)} | "
        f"{c_perf.get('peak_mem_mb', 0) - b_perf.get('peak_mem_mb', 0):+d} |"
    )

    # Per-task diff
    ba = rows_by_id(baseline)
    ca = rows_by_id(candidate)
    all_ids = sorted(set(ba) | set(ca))
    regressions, improvements, still_fail, only_baseline, only_candidate = [], [], [], [], []
    for tid in all_ids:
        if tid not in ca:
            only_baseline.append(tid)
            continue
        if tid not in ba:
            only_candidate.append(tid)
            continue
        cls = classify_task_delta(ba[tid], ca[tid])
        if cls == "regression":
            regressions.append(tid)
        elif cls == "improvement":
            improvements.append(tid)
        elif cls == "still_fail":
            still_fail.append(tid)

    lines += ["", "## Per-task changes", ""]
    if regressions:
        lines.append("### Regressions (pass → fail)")
        lines.append("")
        for tid in regressions:
            b_row = ba[tid]
            c_row = ca[tid]
            lines.append(
                f"- **{tid}** — baseline tsr={b_row.get('tsr')}, "
                f"candidate tsr={c_row.get('tsr')}; "
                f"state={c_row.get('state_verifier', {}).get('detail')}"
            )
        lines.append("")
    if improvements:
        lines.append("### Improvements (fail → pass)")
        lines.append("")
        for tid in improvements:
            lines.append(f"- **{tid}**")
        lines.append("")
    if still_fail:
        lines.append("### Still failing (both runs)")
        lines.append("")
        for tid in still_fail:
            lines.append(f"- {tid}")
        lines.append("")
    if only_baseline or only_candidate:
        lines.append("### Dataset mismatch")
        lines.append("")
        if only_baseline:
            lines.append(f"- only in baseline: {', '.join(only_baseline)}")
        if only_candidate:
            lines.append(f"- only in candidate: {', '.join(only_candidate)}")
        lines.append("")

    if not regressions and not improvements and not still_fail:
        lines.append("_no per-task changes_")
        lines.append("")

    # Verdict
    if oqi_delta > 0.005:
        verdict = "**candidate wins**"
    elif oqi_delta < -0.005:
        verdict = "**regression**"
    else:
        verdict = "**no meaningful change** (|ΔOQI| ≤ 0.005)"
    lines += ["## Verdict", "", f"OQI Δ = {oqi_delta:+.3f} — {verdict}", ""]

    return "\n".join(lines), oqi_delta


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("baseline", help="Baseline run dir (contains results.json)")
    ap.add_argument("candidate", help="Candidate run dir (contains results.json)")
    ap.add_argument("--out", default=None,
                    help="Optional output path for the markdown diff. "
                         "Defaults to <candidate>/compare-vs-<baseline_label>.md")
    args = ap.parse_args()

    baseline_dir = Path(args.baseline)
    candidate_dir = Path(args.candidate)
    try:
        baseline = load_results(baseline_dir)
        candidate = load_results(candidate_dir)
    except FileNotFoundError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    md, oqi_delta = render(baseline, candidate)

    out = Path(args.out) if args.out else (
        candidate_dir / f"compare-vs-{baseline.get('label', 'baseline')}.md"
    )
    out.write_text(md)
    print(md)
    print(f"\n[wrote {out}]", file=sys.stderr)
    return 0 if oqi_delta >= 0 else 1


if __name__ == "__main__":
    sys.exit(main())
