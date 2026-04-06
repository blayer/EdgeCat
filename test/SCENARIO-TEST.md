# Mobile-Claw - On-Device Scenario Test Guide

End-to-end scenario tests for skills and orchestration on a physical Android device using ADB.

## Prerequisites

- macOS with ADB installed (`brew install android-platform-tools` or use `$HOME/Library/Android/sdk/platform-tools/adb`)
- Android device connected via USB with USB debugging enabled
- Mobile-Claw app installed (`com.mobileclaw.app`)
- An LLM model downloaded in the app (e.g., Gemma-4-2B-it)

## Device Setup

1. Connect device via USB, enable USB debugging
2. Verify: `adb devices`

## Running Tests

### Single skill test
```bash
./run-device-test.sh [-d <device-serial>] <skill-name>
```

### Orchestration scenarios
```bash
./run-orchestration-test.sh [-d <device-serial>] [scenario-name]
```

### All orchestration scenarios
```bash
./run-orchestration-test.sh [-d <device-serial>]
```

## App Details

- Package: `com.mobileclaw.app`
- Activity: `com.mobileclaw.app.MobileClawActivity`
- Launch: `adb shell am start -n com.mobileclaw.app/.MobileClawActivity`

## Test Workflow

1. **Push skill** to `/sdcard/Download/<skill-name>` (for JS skills)
2. **Launch app** → Model Select → Tap "Try it" → Agent Chat
3. **Import skill** via Skills panel → Add → Import local skill
4. **Send prompt** and verify response
5. **Check results** via UI dump and screenshots

## ADB Quick Reference

```bash
# Screenshot
adb shell screencap -p /sdcard/screenshot.png && adb pull /sdcard/screenshot.png /tmp/screenshot.png

# UI dump (Compose hierarchy)
adb shell uiautomator dump /sdcard/ui.xml && adb pull /sdcard/ui.xml /tmp/ui.xml

# Tap, type, enter
adb shell input tap <x> <y>
adb shell input text "Hello%sWorld"
adb shell input keyevent 66
```

## Test Scenarios

See `ORCHESTRATION-TEST-PLAN.md` for orchestration scenarios and `TEST-PLAN.md` for individual skill tests.
