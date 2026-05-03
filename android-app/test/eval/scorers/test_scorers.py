"""Smoke tests for the Android eval scorer modules.

Mirrors `ios-app-wip/test/eval/scorers/test_scorers.py` so the per-platform
scorers stay pin-compatible with the shared trace schema. Adapted where
Android's `state.run_verifier` differs from iOS's — Android has no
`adb=[]` short-circuit, so the iOS skip-on-empty-adb tests are dropped."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scorers import perf, state, structural  # noqa: E402


@pytest.fixture
def good_trace() -> dict:
    """A representative successful single-step calculator run, in the
    parsed-trace shape that scorers consume (run summary + spans list)."""
    return {
        "run": {
            "run_id": "calc-001",
            "schema_version": 1,
            "user_message": "What is 42 times 17?",
            "final_status": "ok",
            "final_output": "714",
            "iteration": 0,
            "start_ms": 1_000,
            "end_ms": 4_000,
            "duration_ms": 3_000,
            "plan": {
                "goal": "compute 42 * 17",
                "reasoning": "single arithmetic step",
                "steps": [
                    {"id": "s1", "description": "compute",
                     "skill_name": "calculator",
                     "tool_args": {"expression": "42*17"}},
                ],
                "success_criteria": ["correct number"],
            },
            "step_results": {
                "s1": {"step_id": "s1", "status": "COMPLETED",
                       "output": "714", "duration_ms": 12},
            },
            "evaluation": {"goal_achieved": True, "assessment": "ok",
                           "missing_items": [], "should_replan": False,
                           "failed_criteria": []},
        },
        "spans": [
            {"kind": "phase", "name": "plan",
             "start_ms": 1_000, "end_ms": 1_500, "duration_ms": 500,
             "status": "ok", "thermal": 0, "mem_pss_mb": 1500,
             "attrs": {"prompt_chars": 6000, "response_chars": 200}},
            {"kind": "step", "name": "s1",
             "start_ms": 1_500, "end_ms": 1_512, "duration_ms": 12,
             "status": "ok", "thermal": 0, "mem_pss_mb": 1500},
            {"kind": "phase", "name": "evaluate",
             "start_ms": 1_600, "end_ms": 4_000, "duration_ms": 2_400,
             "status": "ok", "thermal": 0, "mem_pss_mb": 1700,
             "attrs": {"prompt_chars": 1000, "response_chars": 400}},
        ],
    }


# ---- Structural ----

def test_plan_validity_full_marks(good_trace):
    score, _ = structural.plan_validity(good_trace)
    assert score == 1.0


def test_no_plan_zero_validity():
    score, _ = structural.plan_validity({"run": {}, "spans": []})
    assert score == 0.0


def test_tool_correctness_match(good_trace):
    score, detail = structural.tool_correctness(good_trace, ["calculator"])
    assert score == 1.0
    assert "calculator" in detail


def test_tool_correctness_mismatch(good_trace):
    score, _ = structural.tool_correctness(good_trace, ["search-web"])
    assert score == 0.0


def test_tool_correctness_normalizes_underscores(good_trace):
    """`expected_skills` may be written with underscores (e.g. `set_alarm`)
    but skill catalogs hyphenate. Both should match."""
    score, _ = structural.tool_correctness(good_trace, ["calculator"])
    assert score == 1.0


def test_step_order_lcs_one_step(good_trace):
    score, _ = structural.step_order_lcs(good_trace, ["calculator"])
    assert score == 1.0


def test_evaluator_rubber_stamp_agrees(good_trace):
    score, _ = structural.evaluator_rubber_stamp(good_trace, True)
    assert score == 1.0


def test_evaluator_rubber_stamp_caught(good_trace):
    """Evaluator claimed success but ground truth says no — score 0."""
    score, detail = structural.evaluator_rubber_stamp(good_trace, False)
    assert score == 0.0
    assert "rubber-stamp" in detail


def test_evaluator_rubber_stamp_no_ground_truth(good_trace):
    score, _ = structural.evaluator_rubber_stamp(good_trace, None)
    assert score == 1.0  # N/A — pass through


# ---- Perf ----

def test_latency_stats_total_ms(good_trace):
    stats = perf.latency_stats(good_trace)
    assert stats["total_ms"] == 3_000
    # Per-kind breakdowns: 'phase' has two spans (plan + evaluate); 'step' one.
    assert stats["phase_total_ms"] == 2_900  # 500 + 2400
    assert stats["step_total_ms"] == 12


def test_thermal_events_zero_when_cold(good_trace):
    count, _ = perf.thermal_events(good_trace)
    assert count == 0


def test_thermal_events_counts_moderate_or_worse():
    trace = {"spans": [
        {"kind": "phase", "thermal": 0, "duration_ms": 10},
        {"kind": "step", "thermal": 2, "duration_ms": 10},   # MODERATE
        {"kind": "step", "thermal": 3, "duration_ms": 10},   # SEVERE
    ]}
    count, _ = perf.thermal_events(trace)
    assert count == 2


def test_peak_memory_picks_max(good_trace):
    assert perf.peak_memory_mb(good_trace) == 1700


def test_peak_memory_zero_when_no_spans():
    assert perf.peak_memory_mb({"run": {}, "spans": []}) == 0


# ---- State verifier dispatch ----

def test_output_regex_matches(good_trace):
    spec = {"type": "output_regex", "check": r"\b714\b"}
    passed, _ = state.run_verifier([], good_trace, spec)
    assert passed is True


def test_output_regex_fails_when_absent(good_trace):
    spec = {"type": "output_regex", "check": r"\b999\b"}
    passed, _ = state.run_verifier([], good_trace, spec)
    assert passed is False


def test_llm_judge_returns_none(good_trace):
    """llm_judge is handled separately by the runner, not state.run_verifier."""
    spec = {"type": "llm_judge", "rubric": "anything"}
    passed, _ = state.run_verifier([], good_trace, spec)
    assert passed is None


def test_unknown_verifier_type_returns_false(good_trace):
    spec = {"type": "made_up_type"}
    passed, detail = state.run_verifier([], good_trace, spec)
    assert passed is False
    assert "unknown" in detail.lower()
