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
