"""Unit tests for the multi-turn state verifiers in scorers/state.py.

Each verifier is exercised against a synthetic ADB content-query response
patched in via monkeypatch on `state._sh`. Real device queries are not
involved — these tests only validate the parsing + match logic."""
from __future__ import annotations

import datetime as _dt
import sys
from pathlib import Path

import pytest

# This file lives in test/eval/scorers/ — add the parent (test/eval/) to
# sys.path so `from scorers import state` resolves correctly.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scorers import state  # noqa: E402


def _row(title: str, dtstart_ms: int, dtend_ms: int = 0,
         location: str = "", has_alarm: bool = True) -> str:
    """Build a mock content-query row in the format ADB returns."""
    return (f"Row: 0 title={title}, dtstart={dtstart_ms}, "
            f"dtend={dtend_ms or dtstart_ms + 1800_000}, "
            f"eventLocation={location}, hasAlarm={'1' if has_alarm else '0'}")


def _ms(d: _dt.datetime) -> int:
    return int(d.timestamp() * 1000)


def _patch_events(monkeypatch, rows: list[str]) -> None:
    """Make `state._sh` return our synthetic rows for the calendar query."""
    def fake_sh(adb, args, timeout=10):
        return 0, "\n".join(rows) + "\n"
    monkeypatch.setattr(state, "_sh", fake_sh)


def test_reminder_recent_with_substring_finds_recent(monkeypatch) -> None:
    """Reminder created 30 minutes ago should match a 60-minute window."""
    now = _dt.datetime.now()
    _patch_events(monkeypatch, [
        _row("Buy chocolate milk", _ms(now - _dt.timedelta(minutes=30))),
        _row("Old reminder", _ms(now - _dt.timedelta(hours=4))),
    ])
    ok, detail = state.reminder_recent_with_substring(
        ["adb"], {"title_contains": "chocolate", "window_minutes": 60})
    assert ok, detail
    assert "chocolate milk" in detail


def test_reminder_recent_rejects_outside_window(monkeypatch) -> None:
    """Reminder 4 hours old should fail a 60-minute window."""
    now = _dt.datetime.now()
    _patch_events(monkeypatch, [
        _row("Buy chocolate milk", _ms(now - _dt.timedelta(hours=4))),
    ])
    ok, _ = state.reminder_recent_with_substring(
        ["adb"], {"title_contains": "chocolate", "window_minutes": 60})
    assert not ok


def test_reminder_with_title_and_due_matches_dow_and_hour(monkeypatch) -> None:
    """Reminder for the next Friday at 17:00 should match due_dow=friday,
    due_hour_local=17."""
    today = _dt.datetime.now()
    days_to_friday = (4 - today.weekday()) % 7 or 7
    next_fri_5pm = (today + _dt.timedelta(days=days_to_friday)).replace(
        hour=17, minute=0, second=0, microsecond=0)
    _patch_events(monkeypatch, [
        _row("Buy chocolate milk", _ms(next_fri_5pm)),
    ])
    ok, detail = state.reminder_with_title_and_due(["adb"], {
        "title_substring": "chocolate", "due_dow": "friday",
        "due_hour_local": 17, "window_days": 14,
    })
    assert ok, detail


def test_reminder_with_title_and_due_rejects_wrong_dow(monkeypatch) -> None:
    """Saturday reminder should fail due_dow=friday."""
    today = _dt.datetime.now()
    days_to_sat = (5 - today.weekday()) % 7 or 7
    next_sat = (today + _dt.timedelta(days=days_to_sat)).replace(
        hour=17, minute=0, second=0, microsecond=0)
    _patch_events(monkeypatch, [
        _row("Buy chocolate milk", _ms(next_sat)),
    ])
    ok, _ = state.reminder_with_title_and_due(["adb"], {
        "title_substring": "chocolate", "due_dow": "friday",
        "due_hour_local": 17, "window_days": 14,
    })
    assert not ok


def test_reminder_with_title_due_and_location_match(monkeypatch) -> None:
    """All three (title, location, hour on tomorrow) must match."""
    tomorrow_5pm = (_dt.datetime.now() + _dt.timedelta(days=1)).replace(
        hour=17, minute=0, second=0, microsecond=0)
    _patch_events(monkeypatch, [
        _row("Buy chocolate milk", _ms(tomorrow_5pm),
             location="Whole Foods on Stevens Creek"),
    ])
    ok, _ = state.reminder_with_title_due_and_location(["adb"], {
        "title_substring": "chocolate", "location_substring": "stevens creek",
        "date_offset": 1, "due_hour_local": 17,
    })
    assert ok


def test_calendar_event_in_free_slot_passes_when_no_overlap(monkeypatch) -> None:
    """Coffee at 09:00 with another event at 11:00 should be valid: no overlap
    and both before noon."""
    tomorrow = _dt.date.today() + _dt.timedelta(days=1)
    coffee_start = _ms(_dt.datetime.combine(tomorrow, _dt.time(9, 0)))
    coffee_end = _ms(_dt.datetime.combine(tomorrow, _dt.time(9, 30)))
    other_start = _ms(_dt.datetime.combine(tomorrow, _dt.time(11, 0)))
    other_end = _ms(_dt.datetime.combine(tomorrow, _dt.time(12, 0)))
    _patch_events(monkeypatch, [
        _row("coffee with Sam", coffee_start, coffee_end, has_alarm=False),
        _row("standup", other_start, other_end, has_alarm=False),
    ])
    ok, detail = state.calendar_event_in_free_slot(["adb"], {
        "title_substring": "coffee with Sam", "date_offset": 1,
        "before_hour_local": 12, "duration_minutes": 30,
    })
    assert ok, detail


def test_calendar_event_in_free_slot_fails_on_overlap(monkeypatch) -> None:
    """If coffee at 10:00 overlaps an existing 10:00 standup, the verifier
    should reject the event."""
    tomorrow = _dt.date.today() + _dt.timedelta(days=1)
    coffee_start = _ms(_dt.datetime.combine(tomorrow, _dt.time(10, 0)))
    coffee_end = _ms(_dt.datetime.combine(tomorrow, _dt.time(10, 30)))
    other_start = _ms(_dt.datetime.combine(tomorrow, _dt.time(10, 15)))
    other_end = _ms(_dt.datetime.combine(tomorrow, _dt.time(11, 0)))
    _patch_events(monkeypatch, [
        _row("coffee with Sam", coffee_start, coffee_end, has_alarm=False),
        _row("standup", other_start, other_end, has_alarm=False),
    ])
    ok, detail = state.calendar_event_in_free_slot(["adb"], {
        "title_substring": "coffee with Sam", "date_offset": 1,
        "before_hour_local": 12, "duration_minutes": 30,
    })
    assert not ok
    assert "overlap" in detail


def test_run_verifier_dispatches_to_new_verifiers(monkeypatch) -> None:
    """The dispatcher should route the new state verifier names without
    'unknown state verifier' errors."""
    now = _dt.datetime.now()
    _patch_events(monkeypatch, [
        _row("Buy chocolate milk", _ms(now - _dt.timedelta(minutes=10))),
    ])
    spec = {"type": "state", "check": "reminder_recent_with_substring",
            "params": {"title_contains": "chocolate", "window_minutes": 30}}
    ok, _ = state.run_verifier(["adb"], trace={}, verifier_spec=spec)
    assert ok is True


def test_run_verifier_unknown_state_check_returns_false(monkeypatch) -> None:
    """Unknown state verifier names still produce False with a clear detail."""
    spec = {"type": "state", "check": "not_a_real_verifier", "params": {}}
    ok, detail = state.run_verifier(["adb"], trace={}, verifier_spec=spec)
    assert ok is False
    assert "unknown" in detail
