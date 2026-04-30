"""State verifiers — query real Android device state via ADB.

Replaces 'grep "Goal achieved"' pattern matching with ground-truth checks.
Each verifier returns (passed: bool, detail: str).

Usage:
    from scorers.state import run_verifier
    passed, detail = run_verifier(adb, "calendar_event_exists", {"title_contains": "Team Meeting", "hour": 15, "day_offset": 1})
"""
from __future__ import annotations
import datetime as _dt
import re
import subprocess
from typing import Any, Callable


def _sh(adb: list[str], args: list[str], timeout: int = 10) -> tuple[int, str]:
    """Run an adb shell command, return (exit_code, stdout+stderr)."""
    try:
        r = subprocess.run(
            adb + args,
            capture_output=True, text=True, timeout=timeout,
        )
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "adb timeout"
    except Exception as e:
        return 1, f"adb error: {e}"


def calendar_event_exists(adb: list[str], params: dict[str, Any]) -> tuple[bool, str]:
    """Check CalendarContract.Events for a matching event.

    Params:
      title_contains: substring to match in event title
      hour: expected hour (local)
      day_offset: days from today (0=today, 1=tomorrow)
    """
    title_sub = (params.get("title_contains") or "").lower()
    target_hour = params.get("hour")
    day_offset = int(params.get("day_offset", 0))
    target_date = _dt.date.today() + _dt.timedelta(days=day_offset)

    code, out = _sh(adb, [
        "shell", "content", "query",
        "--uri", "content://com.android.calendar/events",
        "--projection", "title:dtstart:dtend",
    ], timeout=15)
    if code != 0:
        return False, f"adb query failed: {out[:200]}"

    matches = []
    for line in out.splitlines():
        # Row example: Row: 0 title=Team Meeting, dtstart=1745956800000, dtend=1745960400000
        if "title=" not in line:
            continue
        m_title = re.search(r"title=([^,]+?)(?:,|$)", line)
        m_start = re.search(r"dtstart=(\d+)", line)
        if not m_title or not m_start:
            continue
        title = m_title.group(1).strip().lower()
        start_ms = int(m_start.group(1))
        start_dt = _dt.datetime.fromtimestamp(start_ms / 1000.0)
        if title_sub and title_sub not in title:
            continue
        if start_dt.date() != target_date:
            continue
        if target_hour is not None and start_dt.hour != int(target_hour):
            continue
        matches.append((title, start_dt.isoformat()))

    if matches:
        return True, f"found {len(matches)}: {matches[0]}"
    return False, f"no event matching title~'{title_sub}' date={target_date} hour={target_hour}"


def alarm_exists(adb: list[str], params: dict[str, Any]) -> tuple[bool, str]:
    """Check for a scheduled alarm via dumpsys alarm."""
    target_hour = params.get("hour")
    target_min = params.get("minute", 0)
    code, out = _sh(adb, ["shell", "dumpsys", "alarm"], timeout=15)
    if code != 0:
        return False, f"dumpsys failed"
    if target_hour is None:
        return ("alarm" in out.lower()), "any alarm presence"
    pattern = rf"\b{int(target_hour):02d}:{int(target_min):02d}\b"
    if re.search(pattern, out):
        return True, f"found alarm at {target_hour:02d}:{target_min:02d}"
    return False, f"no alarm at {target_hour:02d}:{target_min:02d}"


def contact_exists(adb: list[str], params: dict[str, Any]) -> tuple[bool, str]:
    """Check contacts provider for a matching contact."""
    name_sub = (params.get("name_contains") or "").lower()
    code, out = _sh(adb, [
        "shell", "content", "query",
        "--uri", "content://com.android.contacts/contacts",
        "--projection", "display_name",
    ], timeout=15)
    if code != 0:
        return False, "adb query failed"
    for line in out.splitlines():
        m = re.search(r"display_name=([^,]+?)(?:,|$)", line)
        if m and name_sub in m.group(1).strip().lower():
            return True, f"found: {m.group(1).strip()}"
    return False, f"no contact matching '{name_sub}'"


def sms_sent(adb: list[str], params: dict[str, Any]) -> tuple[bool, str]:
    """Check content://sms/sent for a message matching address + body substring.

    Params:
      number: phone number (digits compared with non-digits stripped)
      body_contains: substring to match in message body
    """
    target_num = re.sub(r"\D", "", (params.get("number") or ""))
    body_sub = (params.get("body_contains") or "").lower()
    code, out = _sh(adb, [
        "shell", "content", "query",
        "--uri", "content://sms/sent",
        "--projection", "address:body:date",
    ], timeout=15)
    if code != 0:
        return False, f"adb query failed: {out[:200]}"
    for line in out.splitlines():
        m_addr = re.search(r"address=([^,]+?)(?:,|$)", line)
        m_body = re.search(r"body=(.+?)(?:, date=|$)", line)
        if not m_addr or not m_body:
            continue
        addr = re.sub(r"\D", "", m_addr.group(1).strip())
        body = m_body.group(1).strip().lower()
        if target_num and target_num not in addr:
            continue
        if body_sub and body_sub not in body:
            continue
        return True, f"found sms to {addr}: {body[:60]!r}"
    return False, f"no sms matching num={target_num} body~'{body_sub}'"


def setting_equals(adb: list[str], params: dict[str, Any]) -> tuple[bool, str]:
    """Check a system/global/secure setting via `settings get`.

    Params:
      namespace: 'system' | 'global' | 'secure'
      key: setting key (e.g., 'screen_brightness', 'wifi_on', 'zen_mode')
      expected: expected string or list of acceptable strings
    """
    ns = params.get("namespace", "system")
    key = params.get("key")
    expected = params.get("expected")
    if not key or expected is None:
        return False, "setting_equals needs namespace, key, expected"
    code, out = _sh(adb, ["shell", "settings", "get", ns, key], timeout=10)
    if code != 0:
        return False, f"settings get failed: {out[:120]}"
    actual = out.strip()
    accepted = expected if isinstance(expected, list) else [expected]
    accepted = [str(x) for x in accepted]
    if actual in accepted:
        return True, f"{ns}.{key}={actual}"
    return False, f"{ns}.{key}={actual!r} not in {accepted}"


def timer_set(adb: list[str], params: dict[str, Any]) -> tuple[bool, str]:
    """Check if a timer has been set in the DeskClock app via dumpsys.

    Params:
      minutes: expected minutes (used as rough substring match)
    Notes:
      Samsung/AOSP DeskClock internals differ. This is a best-effort check
      that looks for a non-zero timer in dumpsys output. Absence of a match
      doesn't guarantee no timer (some ROMs don't expose timer state this way).
    """
    minutes = params.get("minutes")
    code, out = _sh(adb, ["shell", "dumpsys", "activity", "service", "deskclock"], timeout=15)
    if code != 0 or not out.strip():
        code, out = _sh(adb, ["shell", "dumpsys", "alarm"], timeout=15)
    if code != 0:
        return False, "dumpsys failed"
    has_timer = bool(re.search(r"timer", out, re.IGNORECASE))
    if minutes is not None:
        if re.search(rf"\b{int(minutes)}\s*(?:min|m)\b", out, re.IGNORECASE):
            return True, f"timer matching {minutes}min present"
        return False, f"no timer for {minutes}min in dumpsys"
    return (has_timer, "timer signal present" if has_timer else "no timer signal")


def output_regex(trace: dict[str, Any], pattern: str) -> tuple[bool, str]:
    """Trace-based verifier: final_output matches regex. No device query."""
    run = trace.get("run", {})
    out = run.get("final_output") or ""
    if re.search(pattern, out):
        return True, f"regex matched: {pattern}"
    return False, f"regex not matched: {pattern} (output[:120]={out[:120]!r})"


VERIFIERS: dict[str, Callable] = {
    "calendar_event_exists": calendar_event_exists,
    "alarm_exists": alarm_exists,
    "contact_exists": contact_exists,
    "sms_sent": sms_sent,
    "setting_equals": setting_equals,
    "timer_set": timer_set,
}


def verify_span_result(
    trace: dict[str, Any],
    kind: str,
) -> tuple[bool | None, str]:
    """Read an in-trace `kind=verify, name=<kind>` span emitted by the
    iOS app's `StateVerifiers.runAndEmit`. Returns (passed, detail) or
    (None, "no span") if the verify URL never reached the app.

    The app emits two spans for one verify call:
      - `kind=verify, name=<kind>` carrying `attrs.passed` ("true"/"false")
        and `attrs.detail`.
      - `kind=verify, name=complete` as the trailing sentinel for the
        runner's file-stability poll.
    We read the first one.
    """
    for span in reversed(trace.get("spans") or []):
        s = span.get("span") or span
        if s.get("kind") == "verify" and s.get("name") == kind:
            attrs = s.get("attrs") or {}
            passed_str = (attrs.get("passed") or "").lower()
            detail = attrs.get("detail") or ""
            if passed_str == "true":
                return True, detail
            if passed_str == "false":
                return False, detail
            return None, f"verify span missing passed attr: {attrs}"
    return None, "no verify span (iOS verifier never ran)"


def run_verifier(
    adb: list[str],
    trace: dict[str, Any],
    verifier_spec: dict[str, Any],
) -> tuple[bool | None, str]:
    """Route a verifier spec to the right checker.

    Returns (passed, detail) or (None, detail) if verifier type is 'none' or 'llm_judge'
    (llm_judge is handled separately by scorers.judge).
    """
    vtype = verifier_spec.get("type")
    if vtype in ("none", "llm_judge"):
        return None, f"skipped: {vtype}"
    if vtype == "output_regex":
        return output_regex(trace, verifier_spec.get("check") or ".*")
    if vtype == "state":
        name = verifier_spec.get("check")
        # iOS path: the runner emits a `edgecat://verify?kind=<name>&…`
        # URL after the eval run, and the in-app `StateVerifiers` writes
        # a verify span into the trace. We just read it here.
        if not adb:
            return verify_span_result(trace, name or "")
        # Android path: shell out to adb.
        fn = VERIFIERS.get(name)
        if fn is None:
            return False, f"unknown state verifier: {name}"
        return fn(adb, verifier_spec.get("params") or {})
    return False, f"unknown verifier type: {vtype}"
