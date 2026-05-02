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


# ─── Calendar/reminder helpers shared by the multi-turn verifiers ───
#
# Android piggybacks reminders on CalendarContract events with `hasAlarm=1`
# (set by DeviceSkills.setReminder via CalendarContract.Reminders), so the
# same content URI serves both event and reminder queries. iOS uses two
# different stores (EKEventStore, EKReminders) — the verifier names mirror
# iOS for dataset compatibility, but the implementation queries one URI
# regardless.

# Day-of-week names accepted in `due_dow` params. Mirrors iOS.
_DOW = {"monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3,
        "friday": 4, "saturday": 5, "sunday": 6}


def _fetch_events(adb: list[str], with_alarm_only: bool = False
                  ) -> tuple[bool, list[dict[str, Any]], str]:
    """Query CalendarContract.Events and parse rows. Returns (ok, events, detail).
    Each event is a dict with title (lower), dtstart_ms, dtend_ms, location
    (lower), has_alarm. `with_alarm_only=True` filters to reminder-style rows."""
    code, out = _sh(adb, [
        "shell", "content", "query",
        "--uri", "content://com.android.calendar/events",
        "--projection", "title:dtstart:dtend:eventLocation:hasAlarm",
    ], timeout=20)
    if code != 0:
        return False, [], f"adb query failed: {out[:160]}"
    events: list[dict[str, Any]] = []
    for line in out.splitlines():
        if "title=" not in line:
            continue
        m_title = re.search(r"title=([^,]+?)(?:,|$)", line)
        m_start = re.search(r"dtstart=(\d+)", line)
        m_end = re.search(r"dtend=(\d+)", line)
        m_loc = re.search(r"eventLocation=([^,]+?)(?:,|$)", line)
        m_alarm = re.search(r"hasAlarm=(\d+)", line)
        if not m_title or not m_start:
            continue
        has_alarm = bool(m_alarm and m_alarm.group(1) == "1")
        if with_alarm_only and not has_alarm:
            continue
        events.append({
            "title": m_title.group(1).strip().lower(),
            "dtstart_ms": int(m_start.group(1)),
            "dtend_ms": int(m_end.group(1)) if m_end else 0,
            "location": (m_loc.group(1).strip().lower() if m_loc else ""),
            "has_alarm": has_alarm,
        })
    return True, events, f"{len(events)} events"


def reminder_recent_with_substring(adb: list[str], params: dict[str, Any]
                                   ) -> tuple[bool, str]:
    """Match a recently-created reminder by title substring.

    Params:
      title_contains: substring to match in event title (case-insensitive)
      window_minutes: how far back to look (default 60)
    """
    title_sub = (params.get("title_contains") or "").lower()
    window_min = int(params.get("window_minutes", 60))
    ok, events, detail = _fetch_events(adb, with_alarm_only=True)
    if not ok:
        return False, detail
    cutoff_ms = int(_dt.datetime.now().timestamp() * 1000) - window_min * 60_000
    for e in events:
        if title_sub and title_sub not in e["title"]:
            continue
        if e["dtstart_ms"] >= cutoff_ms:
            return True, f"found reminder '{e['title']}' within {window_min}min"
    return False, f"no reminder title~'{title_sub}' in last {window_min}min"


def reminder_with_title_and_due(adb: list[str], params: dict[str, Any]
                                ) -> tuple[bool, str]:
    """Match a reminder whose title contains a substring and whose dtstart
    falls on a target day-of-week within `window_days`.

    Params:
      title_substring: substring to match in title (case-insensitive)
      due_dow: weekday name ('monday'..'sunday')
      due_hour_local: optional, exact hour match (0..23)
      window_days: forward search window (default 14)
    """
    title_sub = (params.get("title_substring") or "").lower()
    dow_name = (params.get("due_dow") or "").lower()
    target_hour = params.get("due_hour_local")
    window_days = int(params.get("window_days", 14))
    if dow_name not in _DOW:
        return False, f"due_dow='{dow_name}' not a weekday name"
    target_dow = _DOW[dow_name]
    ok, events, detail = _fetch_events(adb, with_alarm_only=True)
    if not ok:
        return False, detail
    now = _dt.datetime.now()
    for e in events:
        if title_sub and title_sub not in e["title"]:
            continue
        start = _dt.datetime.fromtimestamp(e["dtstart_ms"] / 1000.0)
        if start < now or (start - now).days > window_days:
            continue
        if start.weekday() != target_dow:
            continue
        if target_hour is not None and start.hour != int(target_hour):
            continue
        return True, f"found reminder '{e['title']}' at {start.isoformat()}"
    return (False,
            f"no reminder title~'{title_sub}' on {dow_name} hour={target_hour} "
            f"within {window_days}d")


def reminder_with_title_due_and_location(adb: list[str], params: dict[str, Any]
                                         ) -> tuple[bool, str]:
    """Match a reminder by title substring + location substring + a specific
    day_offset/hour. The location column is `eventLocation` on Android.

    Params:
      title_substring, location_substring: substrings (case-insensitive)
      date_offset: days from today (0=today, 1=tomorrow)
      due_hour_local: expected hour (0..23)
    """
    title_sub = (params.get("title_substring") or "").lower()
    loc_sub = (params.get("location_substring") or "").lower()
    day_offset = int(params.get("date_offset", 1))
    target_hour = params.get("due_hour_local")
    target_date = _dt.date.today() + _dt.timedelta(days=day_offset)
    ok, events, detail = _fetch_events(adb, with_alarm_only=True)
    if not ok:
        return False, detail
    for e in events:
        if title_sub and title_sub not in e["title"]:
            continue
        if loc_sub and loc_sub not in e["location"]:
            continue
        start = _dt.datetime.fromtimestamp(e["dtstart_ms"] / 1000.0)
        if start.date() != target_date:
            continue
        if target_hour is not None and start.hour != int(target_hour):
            continue
        return True, (f"found reminder '{e['title']}' loc='{e['location']}' "
                       f"at {start.isoformat()}")
    return (False,
            f"no reminder title~'{title_sub}' loc~'{loc_sub}' "
            f"date={target_date} hour={target_hour}")


def calendar_event_in_free_slot(adb: list[str], params: dict[str, Any]
                                ) -> tuple[bool, str]:
    """Match a calendar event whose start/end fall inside an actually-free
    window — i.e. it does not overlap any other event on the target day
    before `before_hour_local`.

    Params:
      title_substring: substring (case-insensitive)
      date_offset: days from today (default 1 = tomorrow)
      before_hour_local: gap must be entirely before this hour (default 12)
      duration_minutes: minimum event duration (default 30)
    """
    title_sub = (params.get("title_substring") or "").lower()
    day_offset = int(params.get("date_offset", 1))
    before_hour = int(params.get("before_hour_local", 12))
    min_dur_min = int(params.get("duration_minutes", 30))
    target_date = _dt.date.today() + _dt.timedelta(days=day_offset)
    ok, events, detail = _fetch_events(adb)
    if not ok:
        return False, detail
    same_day = [e for e in events
                if _dt.datetime.fromtimestamp(e["dtstart_ms"] / 1000.0).date()
                == target_date]
    candidate = next((e for e in same_day
                      if title_sub and title_sub in e["title"]
                      and _dt.datetime.fromtimestamp(e["dtstart_ms"] / 1000.0)
                          .hour < before_hour), None)
    if candidate is None:
        return (False,
                f"no event title~'{title_sub}' on {target_date} before "
                f"{before_hour:02d}:00")
    cs, ce = candidate["dtstart_ms"], candidate["dtend_ms"]
    duration_min = (ce - cs) / 60_000 if ce > cs else min_dur_min
    if duration_min + 0.5 < min_dur_min:
        return (False,
                f"event duration {int(duration_min)}min < required {min_dur_min}min")
    for other in same_day:
        if other is candidate:
            continue
        os, oe = other["dtstart_ms"], other["dtend_ms"]
        if cs < oe and os < ce:
            return (False,
                    f"event '{candidate['title']}' overlaps "
                    f"'{other['title']}' on {target_date}")
    return True, (f"event '{candidate['title']}' fits free slot on "
                  f"{target_date} ({int(duration_min)}min)")


VERIFIERS: dict[str, Callable] = {
    "calendar_event_exists": calendar_event_exists,
    "alarm_exists": alarm_exists,
    "contact_exists": contact_exists,
    "sms_sent": sms_sent,
    "setting_equals": setting_equals,
    "timer_set": timer_set,
    "reminder_recent_with_substring": reminder_recent_with_substring,
    "reminder_with_title_and_due": reminder_with_title_and_due,
    "reminder_with_title_due_and_location": reminder_with_title_due_and_location,
    "calendar_event_in_free_slot": calendar_event_in_free_slot,
}


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
        fn = VERIFIERS.get(name)
        if fn is None:
            return False, f"unknown state verifier: {name}"
        return fn(adb, verifier_spec.get("params") or {})
    return False, f"unknown verifier type: {vtype}"
