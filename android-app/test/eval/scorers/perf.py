"""Performance scorers — measured on real device, no simulation.

Surfaces the metrics that matter for a mobile on-device agent:
latency percentiles, thermal events, memory pressure. These are what
cloud/Docker eval cannot capture.
"""
from __future__ import annotations
from typing import Any


def latency_stats(trace: dict[str, Any]) -> dict[str, Any]:
    """End-to-end and per-subsystem latency."""
    run = trace.get("run", {})
    spans = trace.get("spans", [])
    result: dict[str, Any] = {"total_ms": run.get("duration_ms", 0)}
    by_kind: dict[str, list[int]] = {}
    for s in spans:
        kind = s.get("kind")
        d = s.get("duration_ms")
        if kind and d is not None:
            by_kind.setdefault(kind, []).append(d)
    for kind, vals in by_kind.items():
        result[f"{kind}_total_ms"] = sum(vals)
        result[f"{kind}_count"] = len(vals)
        result[f"{kind}_max_ms"] = max(vals)
    return result


def thermal_events(trace: dict[str, Any]) -> tuple[int, str]:
    """Count spans observed under MODERATE-or-worse thermal pressure.

    Android PowerManager thermal status: 0=NONE, 1=LIGHT, 2=MODERATE, 3=SEVERE,
    4=CRITICAL, 5=EMERGENCY, 6=SHUTDOWN.
    """
    MODERATE = 2
    spans = trace.get("spans", [])
    bad = [s for s in spans if (s.get("thermal") or -1) >= MODERATE]
    return len(bad), f"{len(bad)} spans >= MODERATE thermal (of {len(spans)} total)"


def peak_memory_mb(trace: dict[str, Any]) -> int:
    """Peak PSS observed across all spans (MB)."""
    spans = trace.get("spans", [])
    values = [s.get("mem_pss_mb") for s in spans if s.get("mem_pss_mb") is not None and s.get("mem_pss_mb") > 0]
    return max(values) if values else 0


def tokens_per_sec(trace: dict[str, Any]) -> float:
    """Rough tokens/sec across LLM spans.

    Uses response_chars / duration as a proxy when token counts aren't present.
    """
    spans = trace.get("spans", [])
    total_chars = 0
    total_ms = 0
    for s in spans:
        if s.get("kind") not in ("planner", "evaluator", "formatter"):
            continue
        attrs = s.get("attrs") or {}
        chars = attrs.get("response_chars")
        d = s.get("duration_ms")
        if chars and d:
            total_chars += int(chars)
            total_ms += int(d)
    if total_ms == 0:
        return 0.0
    # ~4 chars per token rough heuristic
    return (total_chars / 4.0) / (total_ms / 1000.0)
