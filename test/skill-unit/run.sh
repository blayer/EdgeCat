#!/bin/bash
# Skill Unit Test Runner
#
# Usage:
#   ./test/skill-unit/run.sh [-d <serial>]                     # Run all
#   ./test/skill-unit/run.sh [-d <serial>] calendar             # One skill
#   ./test/skill-unit/run.sh [-d <serial>] calendar/create      # One test
#
# Structure: skill-unit/<skill>/<action>/test.sh

DEVICE_SERIAL=""

while getopts "d:" opt; do
  case $opt in
    d) DEVICE_SERIAL="$OPTARG" ;;
    *) echo "Usage: $0 [-d <device-serial>] [skill[/action]]"; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

FILTER="$1"

if [ -n "$DEVICE_SERIAL" ]; then
  export ADB="adb -s $DEVICE_SERIAL"
else
  export ADB="adb"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$SCRIPT_DIR"
export SCREENSHOTS_DIR="$SCRIPT_DIR/screenshots"
export UI_XML="/tmp/ui_skill_unit_${DEVICE_SERIAL:-default}.xml"
export SKILL_NAME=""
export SKILL_PATH=""

source "$SCRIPT_DIR/../helpers.sh"

mkdir -p "$SCREENSHOTS_DIR"

# ── Device check ──
$ADB get-state >/dev/null 2>&1 || { echo "ERROR: No device connected"; exit 1; }
DEVICE_MODEL=$($ADB shell getprop ro.product.model 2>/dev/null | tr -d '\r')

echo "=========================================="
echo "Skill Unit Tests"
echo "=========================================="
echo "Device: $DEVICE_MODEL (${DEVICE_SERIAL:-default})"
if [ -n "$FILTER" ]; then echo "Filter: $FILTER"; fi
echo ""

# ── Init app ──
echo -n "Initializing app... "
fresh_app
echo "OK"
echo ""

TOTAL=0
PASSED=0
FAILED=0
RESULTS=""

# ── Collect test files ──
TEST_FILES=()

if [ -z "$FILTER" ]; then
  # All tests
  while IFS= read -r f; do
    TEST_FILES+=("$f")
  done < <(find "$TEST_DIR" -name "*_test.sh" -type f | sort)
elif [[ "$FILTER" == *"/"* ]]; then
  # Specific test: calendar/create
  action="$(basename "$FILTER")"
  f="$TEST_DIR/${FILTER}/${action}_test.sh"
  if [ -f "$f" ]; then
    TEST_FILES+=("$f")
  else
    echo "ERROR: Test not found: $f"; exit 1
  fi
else
  # All tests for a skill: calendar
  while IFS= read -r f; do
    TEST_FILES+=("$f")
  done < <(find "$TEST_DIR/$FILTER" -name "test.sh" -type f 2>/dev/null | sort)
  if [ ${#TEST_FILES[@]} -eq 0 ]; then
    echo "ERROR: No tests found for skill: $FILTER"; exit 1
  fi
fi

# ── Run tests ──
for test_file in "${TEST_FILES[@]}"; do
  # Extract skill/action from path: <test_dir>/<skill>/<action>/<action>_test.sh
  test_dir_rel="$(dirname "$test_file")"
  test_id="${test_dir_rel#$TEST_DIR/}"

  echo "------------------------------------------"
  echo "TEST: $test_id"
  echo "------------------------------------------"

  # Source the test file to get PROMPT, PASS_PATTERN, TIMEOUT, SKIP_REASON
  PROMPT=""
  PASS_PATTERN=""
  TIMEOUT=60
  SKIP_REASON=""
  SETUP_CMD=""
  source "$test_file"

  if [ -n "$SKIP_REASON" ]; then
    echo "  SKIP ($SKIP_REASON)"
    echo ""
    RESULTS="${RESULTS}  SKIP  ${test_id} ($SKIP_REASON)\n"
    continue
  fi

  if [ -z "$PROMPT" ] || [ -z "$PASS_PATTERN" ]; then
    echo "  SKIP (missing PROMPT or PASS_PATTERN)"
    echo ""
    continue
  fi

  echo "  Prompt:  \"$PROMPT\""
  echo "  Expect:  \"$PASS_PATTERN\""
  echo "  Timeout: ${TIMEOUT}s"

  # Pre-test setup command (e.g., create calendar event via ADB)
  if [ -n "$SETUP_CMD" ]; then
    echo "  Setup cmd: $SETUP_CMD"
    eval "$SETUP_CMD"
  fi

  # Setup
  echo -n "  Setup... "
  warm_start
  reset_session
  sleep 1
  dump_ui
  if ! ui_has "Type prompt" && ! ui_has "Prompt input"; then
    echo "FAIL - no chat screen"
    TOTAL=$((TOTAL + 1))
    FAILED=$((FAILED + 1))
    RESULTS="${RESULTS}  FAIL  ${test_id}\n"
    echo ""
    continue
  fi
  echo "OK"

  # Run
  echo -n "  Running... "
  send_prompt "$PROMPT"

  PASS=false
  if poll_ui "$PASS_PATTERN" "$TIMEOUT" 3; then
    PASS=true
  fi

  # Screenshot
  sleep 1
  dump_ui
  mkdir -p "$SCREENSHOTS_DIR/$test_id"
  take_screenshot "$SCREENSHOTS_DIR/${test_id}/result.png"

  TOTAL=$((TOTAL + 1))
  if [ "$PASS" = true ]; then
    echo "PASS"
    PASSED=$((PASSED + 1))
    RESULTS="${RESULTS}  PASS  ${test_id}\n"
  else
    echo "FAIL"
    FAILED=$((FAILED + 1))
    RESULTS="${RESULTS}  FAIL  ${test_id}\n"
    echo "  --- UI ---"
    ui_text | grep -v "^Type prompt" | grep -v "^Skills$" | head -15
  fi
  echo ""
done

# ── Summary ──
echo "=========================================="
echo "SUMMARY ($DEVICE_MODEL)"
echo "=========================================="
echo "Total:  $TOTAL"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo ""
if [ -n "$RESULTS" ]; then
  echo -e "$RESULTS"
fi

[ "$FAILED" -eq 0 ] && [ "$TOTAL" -gt 0 ]
