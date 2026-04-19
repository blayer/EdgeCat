"""Structural scorers — model-agnostic, no LLM judge needed.

These compute plan validity and tool correctness from the trace JSON itself.
Each returns (score: float in 0..1, detail: str).
"""
from __future__ import annotations
from typing import Any


def plan_validity(trace: dict[str, Any]) -> tuple[float, str]:
    """Did the planner emit a well-formed plan? 1.0 if yes, 0.0 if no plan at all."""
    run = trace.get("run", {})
    plan = run.get("plan")
    if not plan:
        return 0.0, "no plan emitted"
    steps = plan.get("steps", [])
    if not steps:
        # Empty plan is valid for chat/refuse tasks.
        return 1.0, "empty plan (chat/refuse)"
    for s in steps:
        if "id" not in s or "description" not in s:
            return 0.0, f"step missing id/description: {s}"
        if not s.get("skill_name") and not s.get("tool_name"):
            return 0.0, f"step {s.get('id')} has neither skill_name nor tool_name"
    return 1.0, f"{len(steps)} well-formed steps"


def tool_correctness(trace: dict[str, Any], expected_skills: list[str]) -> tuple[float, str]:
    """Did the planner pick the expected skills? Returns set-overlap ratio.

    - 1.0 if every expected skill appears in the plan.
    - Partial credit: |expected ∩ actual| / |expected|.
    - 1.0 for empty expected (chat/refuse cases — handled separately).
    """
    if not expected_skills:
        return 1.0, "no expected_skills declared"
    run = trace.get("run", {})
    plan = run.get("plan") or {}
    actual = set()
    for s in plan.get("steps", []):
        name = s.get("skill_name") or s.get("tool_name")
        if name:
            actual.add(name.replace("_", "-"))
    expected = {e.replace("_", "-") for e in expected_skills}
    if not expected:
        return 1.0, "no expected_skills after normalization"
    hits = expected & actual
    score = len(hits) / len(expected)
    return score, f"expected={sorted(expected)} actual={sorted(actual)} hits={sorted(hits)}"


def refusal_accuracy(trace: dict[str, Any], should_refuse: bool) -> tuple[float, str]:
    """Did the agent correctly refuse (or not refuse) per the task spec?"""
    run = trace.get("run", {})
    final_output = (run.get("final_output") or "").lower()
    refusal_markers = [
        "i cannot", "i can't", "i don't have", "i am unable",
        "not possible", "unable to", "no skill", "no access",
    ]
    refused = any(m in final_output for m in refusal_markers)
    if should_refuse and refused:
        return 1.0, "correctly refused"
    if should_refuse and not refused:
        return 0.0, "should have refused but did not"
    if not should_refuse and refused:
        return 0.0, "incorrectly refused"
    return 1.0, "correctly attempted"


def evaluator_rubber_stamp(trace: dict[str, Any], state_verifier_passed: bool | None) -> tuple[float, str]:
    """Did the evaluator claim success when ground truth says it failed?

    Returns 1.0 if no rubber-stamp (evaluator agreed with truth), 0.0 if it did.
    Returns 1.0 as N/A when there's no state verifier truth to compare against.
    """
    if state_verifier_passed is None:
        return 1.0, "no ground truth — cannot evaluate rubber-stamp"
    run = trace.get("run", {})
    eval_result = run.get("evaluation") or {}
    agent_said_achieved = bool(eval_result.get("goal_achieved", False))
    if agent_said_achieved and not state_verifier_passed:
        return 0.0, "rubber-stamp: evaluator said goalAchieved=true but state verifier failed"
    return 1.0, f"no rubber-stamp (agent={agent_said_achieved}, truth={state_verifier_passed})"


def replan_convergence(trace: dict[str, Any]) -> tuple[float, str]:
    """For runs that needed replanning, did they converge within maxIterations?"""
    run = trace.get("run", {})
    final_status = run.get("final_status", "")
    iteration = run.get("iteration", 0)
    if iteration <= 1:
        return 1.0, "single iteration — no replan needed"
    if final_status == "COMPLETED":
        return 1.0, f"converged at iteration {iteration}"
    return 0.0, f"failed after {iteration} iterations (status={final_status})"
