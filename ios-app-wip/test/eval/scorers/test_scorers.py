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


# ---- output_regex with reject (false-pass guard) ----

def _trace_with_output(text: str, turn_skills: list[list[str]] | None = None) -> dict:
    """Build a minimal trace with a final_output and per-turn step spans."""
    spans: list[dict] = []
    for turn_idx, skills in enumerate(turn_skills or []):
        spans.append({
            "kind": "eval",
            "name": "start" if turn_idx == 0 else "turn-start",
            "attrs": {"turn": str(turn_idx)},
        })
        for skill in skills:
            spans.append({"kind": "step.start", "name": "s",
                          "attrs": {"skill": skill}})
        spans.append({"kind": "eval", "name": "turn-complete",
                      "attrs": {"status": "ok"}})
    return {"run": {"final_output": text}, "spans": spans}


def test_reject_blocks_apology_false_pass():
    """Anti-pattern: regex matches '30,000 JPY' (the budget in the prompt)
    but the response is actually 'I apologize, I don't have access'. The
    reject regex must veto."""
    trace = _trace_with_output(
        "I apologize, I do not have real-time access. The budget was 30,000 JPY."
    )
    spec = {
        "type": "output_regex",
        "check": r"(?i)\d{1,3}(,\d{3})+\s*jpy",
        "reject": r"(?i)I apologize|do not have (real-time|access)",
    }
    passed, detail = state.run_verifier([], trace, spec)
    assert passed is False
    assert "reject matched" in detail


def test_reject_lets_clean_answer_through():
    trace = _trace_with_output("That's about ¥120,000 JPY total.")
    spec = {
        "type": "output_regex",
        "check": r"(?i)\d{1,3}(,\d{3})+\s*jpy",
        "reject": r"(?i)I apologize|do not have access",
    }
    passed, _ = state.run_verifier([], trace, spec)
    assert passed is True


# ---- forbidden_skills_per_turn (trace-shape assertion) ----

def test_forbidden_skills_catches_redundant_refetch():
    """Weather-cloth Turn 2 should NOT call get-location/search-web — the
    Tokyo weather from Turn 1 is the answer's input."""
    trace = _trace_with_output(
        "Wear a light jacket.",
        turn_skills=[
            ["search-web", "fetch-web-content"],   # Turn 1: legit
            ["get-location", "search-web"],         # Turn 2: forbidden
        ],
    )
    passed, detail = structural.trace_assertions(
        trace, {"forbidden_skills_per_turn": {"2": ["get-location", "search-web"]}})
    assert passed is False
    assert "get-location" in detail or "search-web" in detail


def test_forbidden_skills_passes_when_clean():
    trace = _trace_with_output(
        "Wear a light jacket.",
        turn_skills=[
            ["search-web", "fetch-web-content"],
            ["(llm-only)"],   # Turn 2 synthesis, no re-fetch
        ],
    )
    passed, _ = structural.trace_assertions(
        trace, {"forbidden_skills_per_turn": {"2": ["get-location", "search-web"]}})
    assert passed is True


def test_trace_assertions_returns_none_when_undeclared():
    trace = _trace_with_output("anything", turn_skills=[["search-web"]])
    passed, _ = structural.trace_assertions(trace, {})
    assert passed is None


def test_max_steps_per_turn_catches_overplanning():
    trace = _trace_with_output(
        "ok",
        turn_skills=[["calendar"], ["search-web", "fetch-web-content", "compose"]],
    )
    passed, detail = structural.trace_assertions(
        trace, {"max_steps_per_turn": {"2": 1}})
    assert passed is False
    assert "3 steps" in detail


# ---- required_skills_per_turn (positive trace-shape assertion) ----

def test_required_skills_catches_missing_action():
    """Calendar-gap-fill anti-pattern: agent says 'I added it' but only
    ran `calendar` (read), never `add-calendar-event` (write)."""
    trace = _trace_with_output(
        "I added 'coffee with Sam' for 9:30am.",
        turn_skills=[["calendar"], ["calendar"]],   # Turn 2: read-only
    )
    passed, detail = structural.trace_assertions(
        trace, {"required_skills_per_turn": {"2": ["add-calendar-event"]}})
    assert passed is False
    assert "add-calendar-event" in detail


def test_required_skills_passes_when_present():
    trace = _trace_with_output(
        "Added.",
        turn_skills=[["calendar"], ["calendar", "add-calendar-event"]],
    )
    passed, _ = structural.trace_assertions(
        trace, {"required_skills_per_turn": {"2": ["add-calendar-event"]}})
    assert passed is True


def test_required_skills_fails_when_turn_never_ran():
    """Multi-turn case where turn N timed out before running — should fail
    rather than silently skip (would be a bullshit pass otherwise)."""
    trace = _trace_with_output(
        "(turn 2 never ran)",
        turn_skills=[["calendar"]],   # only turn 1 exists
    )
    passed, detail = structural.trace_assertions(
        trace, {"required_skills_per_turn": {"2": ["add-calendar-event"]}})
    assert passed is False
    assert "did not run" in detail


# ---- LLM judge ----

def test_judge_no_api_key_returns_none(monkeypatch):
    """No ANTHROPIC_API_KEY → judge returns None so the runner doesn't
    false-fail in CI / offline dev."""
    from scorers import judge as judge_mod
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    passed, detail = judge_mod.llm_judge(
        task={"id": "t", "prompt": "p"},
        trace={"run": {"final_output": "x"}, "spans": []},
        spec={"type": "llm_judge", "rubric": "anything"},
    )
    assert passed is None
    assert "ANTHROPIC_API_KEY" in detail


def test_judge_parses_pass_verdict():
    from scorers.judge import _parse_verdict
    passed, detail = _parse_verdict('{"passed": true, "reason": "answers the question"}')
    assert passed is True
    assert "answers the question" in detail


def test_judge_parses_fail_verdict():
    from scorers.judge import _parse_verdict
    passed, detail = _parse_verdict(
        'Some preamble.\n```json\n{"passed": false, "reason": "bailed without answering"}\n```'
    )
    assert passed is False
    assert "bailed without answering" in detail


def test_judge_unparseable_returns_none():
    from scorers.judge import _parse_verdict
    passed, detail = _parse_verdict("yes I think it passed!")
    assert passed is None
    assert "unparseable" in detail


def test_judge_prompt_includes_trace_skills():
    """The judge prompt should surface per-turn tool calls so it can spot
    'agent re-fetched data already in turn 1' even without a forbidden_skills
    rule."""
    from scorers.judge import _build_prompt
    trace = _trace_with_output(
        "Wear a jacket",
        turn_skills=[["search-web", "fetch-web-content"], ["get-location", "search-web"]],
    )
    task = {"turns": [{"prompt": "weather in Tokyo?"},
                       {"prompt": "what should I wear?"}]}
    prompt = _build_prompt(task, trace, {"rubric": "Did the agent use prior turn data?"})
    assert "Turn 1 skills" in prompt
    assert "get-location" in prompt
    assert "weather in Tokyo" in prompt
    assert "Wear a jacket" in prompt
