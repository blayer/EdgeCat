# Mobile-Claw Test Plan

Every change must pass all 3 test levels before merging.
Run them in order — if a level fails, fix before proceeding.

```bash
# Full run (all 3 levels):
./test/run-all.sh [-d <device-serial>]

# Levels 1-2 only (no device):
./test/run-all.sh --skip-device

# Individual levels:
./gradlew testDebugUnitTest --tests "com.mobileclaw.app.orchestration.*" --tests "com.mobileclaw.app.customtasks.*"   # Level 1
./gradlew testDebugUnitTest --tests "com.mobileclaw.app.integration.*"                                                # Level 2
./test/orchestration.sh [-d <serial>]                                                                                 # Level 3
```

---

## Level 1: Unit Tests

Fast, no device required. Tests individual functions in isolation.

**Run:** `./gradlew testDebugUnitTest --tests "com.mobileclaw.app.orchestration.*" --tests "com.mobileclaw.app.customtasks.*"`

| # | Test Class | Area | What It Covers |
|---|-----------|------|----------------|
| 1 | `PlannerTest` | Orchestration | Plan JSON parsing, execution batch ordering, dependency resolution, planning prompt building, replan prompt |
| 2 | `SelfEvaluatorTest` | Orchestration | Evaluation JSON parsing, goal achievement detection, missing items extraction |
| 3 | `ExecutionOrchestratorTest` | Orchestration | Date format normalization, calendar argument normalization |
| 4 | `SkillCreatorTest` | Skill creation | SKILL.md generation prompt, SKILL.md parsing (code block stripping, delimiter handling) |
| 5 | `SkillRepairTest` | Auto-repair | Diagnostic prompt building, diagnostic JSON parsing (all fix types), retryability classification, instruction update |
| 6 | `CalculatorTest` | Utility | Expression evaluation, operator precedence, math functions |
| 7 | `HtmlExtractorTest` | Utility | HTML-to-text extraction, search result parsing |
| 8 | `DateTimeParsingTest` | Utility | Flexible date/time format parsing, garbled LLM output handling |

**Test files:** `app/src/test/java/com/mobileclaw/app/orchestration/` and `app/src/test/java/com/mobileclaw/app/customtasks/agentchat/`

---

## Level 2: Integration Tests

No device required. Tests end-to-end flows with mock LLM responses.

**Run:** `./gradlew testDebugUnitTest --tests "com.mobileclaw.app.integration.*"`

| # | Test Class | Area | What It Covers |
|---|-----------|------|----------------|
| 1 | `EndToEndSkillFlowTest` | Save as Skill | Full prompt-to-save-to-replay flow: plan, execute, evaluate, generate SKILL.md, parse back, replay with new input |
| 2 | `SkillCreatorIntegrationTest` | Skill creation | Skill creation prompt context, realistic LLM output parsing, saved skill reuse in planner, skill name normalization |
| 3 | `AutoRepairFlowTest` | Auto-repair | Full repair loop: fail, diagnose, replan with fixed args; skill swap after intent failure; partial success replan |

**Test files:** `app/src/test/java/com/mobileclaw/app/integration/`

---

## Level 3: On-Device Tests

Requires ADB + connected device + LLM model loaded. Tests real scenarios on physical hardware.

```bash
# All orchestration scenarios:
./test/orchestration.sh [-d <serial>]

# Single scenario:
./test/orchestration.sh [-d <serial>] <scenario-name>

# Individual skill tests:
./test/device.sh [-d <serial>] [-s <skills-dir>] <skill-name>

# Multi-device parallel:
./test/parallel.sh [-s <skills-dir>] [skill1 skill2 ...]
```

### Scenario Tests — Individual Skills

Test workflow:
1. Push skill to `/sdcard/Download/<skill-name>`
2. Launch app → Model Select → Tap "Try it" → Agent Skills screen
3. Import skill via Skills panel → Add skill → Import local skill
4. Send prompt and verify response
5. Capture screenshot

| # | Skill | Test Prompt | Passed | Notes |
|---|-------|------------|--------|-------|
| 1 | calculator | What is 42 times 17? | | Base skill |
| 2 | device-info | Show my device info | | Base skill |
| 3 | search-web | Search the web for Claude AI | | Base skill |
| 4 | set-reminder | Set a reminder for tomorrow at 9am to exercise | | Base skill |
| 5 | clipboard | Copy this to clipboard: test123 | | Base skill |
| 6 | summarize | Summarize this: The quick brown fox jumps over the lazy dog | | Base skill |

### Orchestration Scenarios

| # | Scenario | Skills | Test Prompt | Pass Pattern | Timeout |
|---|----------|--------|-------------|-------------|---------|
| 1 | single-native-skill | (none) | What is 42 times 17? | Goal achieved | 90 |
| 2 | two-skill-chain | (none) | Get my device info and calculate the hash of the manufacturer name | Goal achieved | 180 |
| 3 | web-and-summarize | (none) | Search the web for latest Android news and summarize it | Goal achieved | 240 |
| 4 | reminder-test | (none) | Set a reminder for tomorrow at 9am to buy groceries | Goal achieved | 120 |
| 5 | multi-step-plan | (none) | Look up the weather in Tokyo and copy the summary to clipboard | Goal achieved | 240 |

### Auto-Repair Scenarios

| # | Scenario | Skills | Test Prompt | Pass Pattern | Timeout |
|---|----------|--------|-------------|-------------|---------|
| 6 | repair-fallback | (none) | Create a calendar event for tomorrow at 3pm called Team Meeting | Goal achieved | 300 |

---

## Prerequisites

- **Levels 1-2:** JDK 17+, Android SDK (for Robolectric)
- **Level 3:** macOS with ADB (`brew install android-platform-tools`), Android device connected via USB with USB debugging enabled, Mobile-Claw app installed (`com.mobileclaw.app`), LLM model downloaded (e.g., Gemma-4-2B-it)

## App Details

- Package: `com.mobileclaw.app`
- Activity: `com.mobileclaw.app.MobileClawActivity`
- Launch: `adb shell am start -n com.mobileclaw.app/.MobileClawActivity`

---

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
