"""LLM-as-judge backend for cases that regex/trace/state can't grade.

Used as a *gating* check rather than the primary verifier — call sites should
run cheap deterministic checks first, then escalate ambiguous cases here.
That keeps API spend bounded and gives the regex/state checks first crack.

Verifier spec shape (added to a `verifier` block):
  {
    "type": "llm_judge",
    "rubric": "Did the assistant actually convert $800 to JPY using a real rate?",
    "criteria": ["uses an exchange rate from search results, not a guess",
                 "shows the JPY total or the final 'N nights' answer"],
    "model": "claude-haiku-4-5"  // optional, default haiku
  }

Returns (passed: bool|None, detail: str). None when no API key is set, so
runs without ANTHROPIC_API_KEY don't false-fail. Detail surfaces the
judge's reason so failures are debuggable from the report alone.
"""
from __future__ import annotations
import json
import os
import re
import urllib.error
import urllib.request
from typing import Any


_API_URL = "https://api.anthropic.com/v1/messages"
_DEFAULT_MODEL = "claude-haiku-4-5"
_DEFAULT_MAX_TOKENS = 256


def _build_prompt(task: dict[str, Any], trace: dict[str, Any], spec: dict[str, Any]) -> str:
    """Compose a focused judge prompt with task + trace + final response."""
    rubric = (spec.get("rubric") or "").strip()
    criteria = spec.get("criteria") or []
    criteria_block = ""
    if criteria:
        criteria_block = "Pass criteria (ALL must hold):\n" + "\n".join(
            f"  - {c}" for c in criteria
        ) + "\n\n"

    turns = task.get("turns") or [{"prompt": task.get("prompt", "")}]
    user_block = "\n".join(f"Turn {i+1} user: {t.get('prompt','')}" for i, t in enumerate(turns))

    run = trace.get("run") or {}
    final_output = (run.get("final_output") or "").strip()

    # Compact trace shape: per-turn skill list + final response. Avoid
    # dumping the full step outputs (cost) — judge needs intent, not data.
    spans = trace.get("spans") or []
    per_turn_skills = _bucket_skills(spans)
    trace_block = "\n".join(
        f"Turn {i+1} skills: {skills or ['(none — no plan ran)']}"
        for i, skills in enumerate(per_turn_skills)
    )

    return (
        "You are an eval judge. Grade an agentic assistant's response.\n\n"
        f"Task:\n{user_block}\n\n"
        f"Rubric: {rubric or '(no rubric — check if response answers the task)'}\n\n"
        f"{criteria_block}"
        f"Agent's per-turn tool calls:\n{trace_block}\n\n"
        f"Agent's final response:\n{final_output}\n\n"
        "Return STRICT JSON only — no markdown, no preamble:\n"
        '{"passed": <true|false>, "reason": "<one sentence>"}'
    )


def _bucket_skills(spans: list[dict[str, Any]]) -> list[list[str]]:
    """Mirror the trace_assertions bucketing — per-turn skill list."""
    turns: list[list[str]] = []
    current: list[str] | None = None
    for s in spans:
        attrs = s.get("attrs") or {}
        kind, name = s.get("kind"), s.get("name")
        if kind == "eval" and name in ("start", "turn-start"):
            if current is not None:
                turns.append(current)
            current = []
        elif current is None:
            continue
        elif kind == "step.start":
            current.append(attrs.get("skill") or "(llm-only)")
        elif kind == "eval" and name == "turn-complete":
            turns.append(current)
            current = None
    if current is not None:
        turns.append(current)
    return turns


def _call_anthropic(prompt: str, model: str, api_key: str) -> str:
    """POST to Anthropic Messages API; return the assistant's text."""
    body = json.dumps({
        "model": model,
        "max_tokens": _DEFAULT_MAX_TOKENS,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()
    req = urllib.request.Request(
        _API_URL,
        data=body,
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        payload = json.loads(resp.read().decode())
    blocks = payload.get("content") or []
    for b in blocks:
        if b.get("type") == "text":
            return b.get("text") or ""
    return ""


def _parse_verdict(text: str) -> tuple[bool | None, str]:
    """Pull `{"passed": bool, "reason": str}` out of the judge response.

    Tolerant of code fences and stray prose: searches for the first JSON
    object with a `passed` key. Returns (None, ...) if unparseable so a
    bad response doesn't false-fail an honest run.
    """
    if not text:
        return None, "judge returned empty text"
    # Try to find the first object containing "passed".
    m = re.search(r'\{[^{}]*"passed"\s*:\s*(true|false)[^{}]*\}', text, re.DOTALL)
    if not m:
        return None, f"judge response unparseable: {text[:200]!r}"
    try:
        obj = json.loads(m.group(0))
    except json.JSONDecodeError:
        return None, f"judge JSON malformed: {m.group(0)[:200]!r}"
    passed = obj.get("passed")
    reason = (obj.get("reason") or "").strip() or "no reason given"
    if passed is True:
        return True, f"judge passed: {reason}"
    if passed is False:
        return False, f"judge failed: {reason}"
    return None, f"judge passed-field not bool: {passed!r}"


def llm_judge(
    task: dict[str, Any],
    trace: dict[str, Any],
    spec: dict[str, Any],
) -> tuple[bool | None, str]:
    """Run the LLM judge for a verifier spec of type llm_judge.

    Returns (None, ...) when no API key is set so CI / offline dev still
    works — the runner falls back to the cheap deterministic checks.
    """
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        return None, "no ANTHROPIC_API_KEY — judge skipped"
    model = spec.get("model") or _DEFAULT_MODEL
    prompt = _build_prompt(task, trace, spec)
    try:
        text = _call_anthropic(prompt, model=model, api_key=api_key)
    except urllib.error.HTTPError as e:
        return None, f"judge HTTP {e.code}: {e.reason}"
    except urllib.error.URLError as e:
        return None, f"judge network error: {e.reason}"
    except Exception as e:  # noqa: BLE001
        return None, f"judge error: {e}"
    return _parse_verdict(text)
