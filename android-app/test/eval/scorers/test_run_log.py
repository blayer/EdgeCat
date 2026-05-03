"""Unit tests for `render_run_log` in run.py.

Drives the renderer against a synthetic trace JSONL to verify per-turn
metrics (latency, char/token approximations) surface in the rendered
Markdown, and that the back-compat path (no `eval.start` span) still
produces a usable log."""
from __future__ import annotations

import json
from pathlib import Path

import pytest

import sys
# This file lives in test/eval/scorers/ — add the parent (test/eval/) to
# sys.path so `import run` resolves to test/eval/run.py.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from run import render_run_log, _render_task_turns  # noqa: E402


def _write_trace(path: Path, lines: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(l) for l in lines))


def test_render_run_log_emits_per_turn_metrics(tmp_path: Path) -> None:
    """When the trace has the new `turn-response` span, the rendered log
    surfaces latency + token approximations as a stats line."""
    traces = tmp_path / "traces"
    _write_trace(
        traces / "task-001.jsonl",
        [
            {"type": "span", "run_id": "task-001", "span": {
                "kind": "eval", "name": "start",
                "attrs": {"turn": "0", "prompt": "what is 2+2"},
            }},
            {"type": "span", "run_id": "task-001", "span": {
                "kind": "eval", "name": "turn-response",
                "attrs": {
                    "turn": "0", "run_id": "task-001",
                    "text": "4",
                    "iteration": "0",
                    "duration_ms": "2500",
                    "history_chars": "11",
                    "response_chars": "1",
                    "approx_history_tokens": "2",
                    "approx_response_tokens": "0",
                },
            }},
            {"type": "span", "run_id": "task-001", "span": {
                "kind": "eval", "name": "turn-complete",
                "attrs": {"turn": "0", "status": "ok"},
            }},
            {"type": "run", "run": {
                "run_id": "task-001",
                "user_message": "what is 2+2",
                "final_output": "4",
                "final_status": "ok",
                "iteration": 0,
                "plan": {"goal": "compute 2+2", "reasoning": "use calculator"},
            }},
        ],
    )
    rows = [{"task_id": "task-001", "tsr": 1.0, "state_verifier": {"passed": True}}]
    log = render_run_log(
        label="test", dataset="datasets/x.jsonl",
        summary={"tsr": 1.0, "oqi": 0.95, "n_tasks": 1},
        rows=rows, traces_dir=traces,
    )
    assert "task-001 — TSR=100%, verifier=pass" in log
    assert "what is 2+2" in log
    assert "Latency: 2.5s" in log
    assert "memory in: ~2 tok (11 chars)" in log
    assert "response out: ~0 tok (1 chars)" in log
    assert "**Plan goal:** compute 2+2" in log
    assert "**Assistant:** 4" in log


def test_render_run_log_back_compat_synthesizes_turn(tmp_path: Path) -> None:
    """Older Android traces don't emit `eval.start` / `eval.turn-response`.
    The renderer should fall back to the run summary and still produce a
    turn block instead of '_(no turn spans)_'."""
    traces = tmp_path / "traces"
    _write_trace(
        traces / "old-001.jsonl",
        [
            {"type": "run", "run": {
                "run_id": "old-001",
                "user_message": "set timer 5 min",
                "final_output": "Timer set for 5 minutes.",
                "final_status": "ok",
                "iteration": 0,
            }},
        ],
    )
    rows = [{"task_id": "old-001", "tsr": 1.0, "state_verifier": {"passed": True}}]
    log = render_run_log(
        label="test", dataset="datasets/x.jsonl",
        summary={"tsr": 1.0, "oqi": 1.0, "n_tasks": 1},
        rows=rows, traces_dir=traces,
    )
    assert "_(no turn spans" not in log
    assert "set timer 5 min" in log
    assert "Timer set for 5 minutes." in log
    # No duration_ms attr in old traces — stats line should be absent.
    assert "Latency:" not in log


def test_render_run_log_handles_missing_trace_file(tmp_path: Path) -> None:
    """A row with no corresponding trace file (e.g. `am start` failed
    before flush) should render with a placeholder, not crash."""
    traces = tmp_path / "traces"
    traces.mkdir()
    rows = [{"task_id": "missing-001", "tsr": 0.0,
             "state_verifier": {"passed": False}}]
    log = render_run_log(
        label="test", dataset="datasets/x.jsonl",
        summary={"tsr": 0.0, "oqi": 0.0, "n_tasks": 1},
        rows=rows, traces_dir=traces,
    )
    assert "missing-001 — TSR=0%, verifier=fail" in log
    assert "no trace file" in log


def test_render_task_turns_buckets_steps(tmp_path: Path) -> None:
    """`step.start` / `step.end` spans between `eval.start` and
    `eval.turn-complete` should land inside the current turn's steps list."""
    trace = tmp_path / "t.jsonl"
    _write_trace(trace, [
        {"type": "span", "span": {"kind": "eval", "name": "start",
                                   "attrs": {"turn": "0", "prompt": "p"}}},
        {"type": "span", "span": {"kind": "step.start", "name": "step_1",
                                   "attrs": {"skill": "search-web"}}},
        {"type": "span", "span": {"kind": "step.end", "name": "step_1",
                                   "attrs": {"ok": "1", "tool": "search-web"}}},
        {"type": "span", "span": {"kind": "eval", "name": "turn-complete",
                                   "attrs": {"status": "ok"}}},
        {"type": "run", "run": {"final_output": "done"}},
    ])
    md = "\n".join(_render_task_turns(trace, {"task_id": "t"}))
    assert "step_1 [ok] search-web" in md


def test_render_phase_breakdown_and_step_durations(tmp_path: Path) -> None:
    """Android traces emit kind=planner/evaluator/formatter/step phase
    spans alongside eval.* turn markers. The renderer should sum each
    phase's wall-time into the per-turn '_Phases:' line and lift step
    durations from `attrs.duration_ms` (the outer span's duration_ms is
    0 because steps are emitted as RUNNING + COMPLETED markers, not
    wrapped phases). Sort-by-start_ms is required because TraceRecorder
    serializes spans in `.end()` order — `eval.start` ends LAST."""
    traces = tmp_path / "traces"
    def span(kind, name, start_ms, end_ms, attrs=None, status="ok"):
        return {"type": "span", "span": {
            "kind": kind, "name": name,
            "start_ms": start_ms, "end_ms": end_ms,
            "duration_ms": end_ms - start_ms,
            "status": status,
            "attrs": attrs or {},
        }}
    # File order is reverse-end (matches TraceRecorder behavior). The
    # renderer must sort by start_ms to recover the bucketing order.
    rows = [
        # planner phase 1.5s, two step pairs, evaluator triage 0.2s,
        # formatter 0.3s — all inside an eval.start that ends last.
        span("memory", "recall", 100, 150, {}, "ok"),
        span("planner", "plan", 150, 1650, {}, "ok"),
        span("step", "step_1", 1700, 1700, {"skill": "step_1",
              "status": "RUNNING", "duration_ms": 0}, "error"),
        span("step", "step_1", 2700, 2700, {"skill": "step_1",
              "status": "COMPLETED", "duration_ms": 1000}, "ok"),
        span("step", "step_2", 2800, 2800, {"skill": "step_2",
              "status": "RUNNING", "duration_ms": 0}, "error"),
        span("step", "step_2", 3300, 3300, {"skill": "step_2",
              "status": "COMPLETED", "duration_ms": 500}, "ok"),
        span("evaluator", "triage", 3400, 3600, {}, "ok"),
        span("formatter", "llm", 3600, 3900, {}, "ok"),
        span("eval", "turn-response", 3950, 3950, {
            "turn": "0", "text": "weather is sunny",
            "iteration": "0", "duration_ms": "3850",
            "history_chars": "20", "response_chars": "16",
            "approx_history_tokens": "5", "approx_response_tokens": "4",
        }),
        span("eval", "turn-complete", 3960, 3960, {"turn": "0", "status": "ok"}),
        span("eval", "start", 100, 3960, {"turn": "0", "prompt": "weather?"}),
        {"type": "run", "run": {
            "user_message": "weather?", "final_output": "weather is sunny",
            "final_status": "ok", "iteration": 0,
            "plan": {"goal": "find weather",
                      "steps": [
                          {"id": "step_1", "skill_name": "search-web"},
                          {"id": "step_2", "skill_name": "fetch-web-content"},
                      ]},
            "step_results": {"step_1": {"output": "tokyo: sunny"},
                             "step_2": {"output": "details..."}},
        }},
    ]
    _write_trace(traces / "phase-001.jsonl", rows)
    log = render_run_log(
        label="t", dataset="datasets/x.jsonl",
        summary={"tsr": 1.0, "oqi": 1.0, "n_tasks": 1},
        rows=[{"task_id": "phase-001", "tsr": 1.0,
               "state_verifier": {"passed": True}}],
        traces_dir=traces,
    )
    assert "_Phases:" in log
    assert "planner 1.5s" in log
    assert "execute 1.5s (2 steps)" in log  # 1.0s + 0.5s, 0 orchestrator
    assert "evaluator 0.2s" in log
    assert "formatter 0.3s" in log
    # Step rows surface the actual skill name from the plan + per-step
    # duration from attrs.duration_ms (NOT the outer span's 0ms).
    assert "step_1 [ok] search-web (1.0s)" in log
    assert "step_2 [ok] fetch-web-content (0.5s)" in log
    # Per-step output preview
    assert "tokyo: sunny" in log
    # Steps deduped — no second row per step despite RUNNING + COMPLETED.
    assert log.count("step_1 [ok]") == 1
    assert log.count("step_2 [ok]") == 1


def test_render_run_log_multi_turn_renders_each_turn(tmp_path: Path) -> None:
    """A multi-turn trace (eval.start + eval.turn-start + per-turn complete)
    should render distinct ### Turn 1 / ### Turn 2 sections, each with its
    own latency line and assistant text."""
    traces = tmp_path / "traces"
    spans = [
        # Turn 0
        {"type": "span", "span": {"kind": "eval", "name": "start",
            "attrs": {"turn": "0", "prompt": "weather in Tokyo?"}}},
        {"type": "span", "span": {"kind": "eval", "name": "turn-response",
            "attrs": {"turn": "0", "text": "It is rainy in Tokyo.",
                      "iteration": "0", "duration_ms": "1500",
                      "history_chars": "17", "response_chars": "21",
                      "approx_history_tokens": "4",
                      "approx_response_tokens": "5"}}},
        {"type": "span", "span": {"kind": "eval", "name": "turn-complete",
            "attrs": {"turn": "0", "status": "ok"}}},
        # Turn 1
        {"type": "span", "span": {"kind": "eval", "name": "turn-start",
            "attrs": {"turn": "1", "prompt": "what should I wear?"}}},
        {"type": "span", "span": {"kind": "eval", "name": "turn-response",
            "attrs": {"turn": "1", "text": "Bring an umbrella and a jacket.",
                      "iteration": "0", "duration_ms": "2200",
                      "history_chars": "60", "response_chars": "32",
                      "approx_history_tokens": "15",
                      "approx_response_tokens": "8"}}},
        {"type": "span", "span": {"kind": "eval", "name": "turn-complete",
            "attrs": {"turn": "1", "status": "ok"}}},
        {"type": "run", "run": {"final_output": "Bring an umbrella and a jacket.",
                                "user_message": "weather in Tokyo?"}},
    ]
    _write_trace(traces / "multi-001.jsonl", spans)
    rows = [{"task_id": "multi-001", "tsr": 1.0,
             "state_verifier": {"passed": True}}]
    log = render_run_log(
        label="t", dataset="datasets/v3_multi_turn.jsonl",
        summary={"tsr": 1.0, "oqi": 0.9, "n_tasks": 1},
        rows=rows, traces_dir=traces,
    )
    assert "### Turn 1" in log and "### Turn 2" in log
    assert "weather in Tokyo?" in log
    assert "what should I wear?" in log
    assert "It is rainy in Tokyo." in log
    assert "Bring an umbrella and a jacket." in log
    assert "Latency: 1.5s" in log  # turn 0
    assert "Latency: 2.2s" in log  # turn 1
    assert log.count("### Turn") == 2
