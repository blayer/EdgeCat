"""Smoke tests for the ported scorers. Run with `python -m pytest`.

These tests prove that the Android scorer modules produce sensible scores
on iOS-shape traces — i.e. the schema parity work in TraceRecorder.swift
held up. Bare-bones; the Android side has fuller fixtures.
"""
from __future__ import annotations
import json
from pathlib import Path

import pytest

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scorers import structural, perf, state


# A representative iOS trace — what `EvalEntryPoint.run` emits for a
# successful `calc 2+2` agentic run.
@pytest.fixture
def good_trace() -> dict:
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
                     "tool_args": {"expression": "42*17"}}
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


def test_tool_correctness_match(good_trace):
    score, detail = structural.tool_correctness(good_trace, ["calculator"])
    assert score == 1.0
    assert "calculator" in detail


def test_tool_correctness_mismatch(good_trace):
    score, _ = structural.tool_correctness(good_trace, ["search-web"])
    assert score == 0.0


def test_no_plan_zero_validity():
    score, _ = structural.plan_validity({"run": {}, "spans": []})
    assert score == 0.0


def test_evaluator_rubber_stamp_agrees(good_trace):
    score, _ = structural.evaluator_rubber_stamp(good_trace, True)
    assert score == 1.0


# ---- Perf ----

def test_latency_stats_total_ms(good_trace):
    stats = perf.latency_stats(good_trace)
    assert stats["total_ms"] == 3_000
    # Per-kind breakdowns: 'phase' has two spans (plan + evaluate); 'step' has one.
    assert "phase_total_ms" in stats
    assert stats["phase_total_ms"] == 2_900  # 500 + 2400
    assert stats["step_total_ms"] == 12


def test_thermal_events_zero_when_cold(good_trace):
    count, _ = perf.thermal_events(good_trace)
    assert count == 0


def test_thermal_events_counts_moderate():
    trace = {"spans": [{"kind": "phase", "thermal": 0, "duration_ms": 10},
                      {"kind": "step", "thermal": 2, "duration_ms": 10},
                      {"kind": "step", "thermal": 3, "duration_ms": 10}]}
    count, _ = perf.thermal_events(trace)
    assert count == 2


def test_peak_memory_picks_max(good_trace):
    assert perf.peak_memory_mb(good_trace) == 1700


# ---- State verifier ----

def test_output_regex_matches(good_trace):
    spec = {"type": "output_regex", "check": r"\b714\b"}
    passed, _ = state.run_verifier([], good_trace, spec)
    assert passed is True


def test_output_regex_fails_when_absent(good_trace):
    spec = {"type": "output_regex", "check": r"\b999\b"}
    passed, _ = state.run_verifier([], good_trace, spec)
    assert passed is False


def test_state_verifier_skipped_on_ios():
    """When `adb=[]` (iOS short-circuit), state-type verifiers return None
    so the run isn't unfairly flagged as a failure."""
    spec = {"type": "state", "check": "calendar_event_exists",
            "params": {"title_contains": "x"}}
    passed, detail = state.run_verifier([], {"run": {}, "spans": []}, spec)
    assert passed is None
    assert "ios" in detail.lower()


def test_llm_judge_returns_none(good_trace):
    """llm_judge is handled separately by the runner, not state.run_verifier."""
    spec = {"type": "llm_judge", "rubric": "anything"}
    passed, _ = state.run_verifier([], good_trace, spec)
    assert passed is None
