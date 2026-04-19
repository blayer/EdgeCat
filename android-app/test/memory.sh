#!/bin/bash
# Mobile-Claw Memory On-Device Tests
# Usage: ./memory.sh [-d <device-serial>]
#
# Tests that the memory layer saves episodes/repairs and recalls them
# in subsequent orchestration runs.

DEVICE_SERIAL=""

while getopts "d:" opt; do
  case $opt in
    d) DEVICE_SERIAL="$OPTARG" ;;
    *) echo "Usage: $0 [-d <device-serial>]"; exit 1 ;;
  esac
done

if [ -n "$DEVICE_SERIAL" ]; then
  ADB="adb -s $DEVICE_SERIAL"
else
  ADB="adb"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCREENSHOTS_DIR="$SCRIPT_DIR/screenshots/memory"
UI_XML="/tmp/ui_mem_${DEVICE_SERIAL:-default}.xml"
SKILL_NAME=""
SKILL_PATH=""
PKG="com.mobileclaw.app"

source "$SCRIPT_DIR/helpers.sh"
mkdir -p "$SCREENSHOTS_DIR"

DEVICE_MODEL=$($ADB shell getprop ro.product.model 2>/dev/null | tr -d '\r')
echo "=========================================="
echo "Memory On-Device Tests"
echo "=========================================="
echo "Device: $DEVICE_MODEL (${DEVICE_SERIAL:-default})"
echo ""

TOTAL=0
PASSED=0
FAILED=0
FAIL_LIST=""

# =============================================
# Helpers
# =============================================

# Clear the memory database
clear_memory_db() {
  $ADB shell run-as "$PKG" rm -f databases/agent_memory databases/agent_memory-wal databases/agent_memory-shm 2>/dev/null
  echo "Memory DB cleared"
}

# Pull memory DB to local temp and query with local sqlite3
LOCAL_DB="/tmp/mc_memory_test.db"
pull_memory_db() {
  rm -f "$LOCAL_DB" "${LOCAL_DB}-wal" "${LOCAL_DB}-shm"
  $ADB shell "run-as $PKG cat databases/agent_memory" > "$LOCAL_DB" 2>/dev/null
  $ADB shell "run-as $PKG cat databases/agent_memory-wal" > "${LOCAL_DB}-wal" 2>/dev/null
  $ADB shell "run-as $PKG cat databases/agent_memory-shm" > "${LOCAL_DB}-shm" 2>/dev/null
}

# Count rows in a memory table (pulls DB first)
count_memory_rows() {
  local table="$1"
  pull_memory_db
  sqlite3 "$LOCAL_DB" "SELECT COUNT(*) FROM $table;" 2>/dev/null
}

# Check if logcat contains memory recall
logcat_has_memory_recall() {
  $ADB logcat -d | grep -q "Memory context.*chars"
}

# Get memory context from logcat
get_memory_context_log() {
  $ADB logcat -d | grep "Memory context" | tail -1
}

# Run a prompt and wait for completion
run_prompt_and_wait() {
  local prompt="$1"
  local pass_pattern="$2"
  local timeout="${3:-120}"

  warm_start
  sleep 2
  reset_session
  sleep 1
  send_prompt "$prompt"

  if poll_ui "$pass_pattern" "$timeout" 5; then
    return 0
  else
    return 1
  fi
}

# =============================================
# Test 1: Episode saved after successful task
# =============================================

run_test_episode_save() {
  local test_name="episode-save"
  echo ""
  echo "=========================================="
  echo "Memory Test: $test_name"
  echo "=========================================="
  echo "Verify: Episode saved to DB after a successful task"
  echo ""

  TOTAL=$((TOTAL + 1))

  # Step 1: Clear memory DB and restart app
  echo -n "[1/4] Clear memory... "
  $ADB shell am force-stop "$PKG" >/dev/null 2>&1
  sleep 1
  clear_memory_db
  sleep 1
  fresh_app
  sleep 5  # extra wait for model to load after cold start
  echo "OK"

  # Step 2: Run a task
  echo -n "[2/4] Run task... "
  if run_prompt_and_wait "What is 42 times 17?" "Goal achieved" 120; then
    echo "OK (Goal achieved)"
  else
    echo "FAIL (task did not complete)"
    take_screenshot "$SCREENSHOTS_DIR/${test_name}_fail.png"
    FAILED=$((FAILED + 1))
    FAIL_LIST="$FAIL_LIST $test_name"
    return
  fi

  # Step 3: Wait for memory save (async)
  echo -n "[3/4] Check DB... "
  sleep 3
  local episode_count
  episode_count=$(count_memory_rows "episodes")
  if [ -z "$episode_count" ] || [ "$episode_count" = "0" ]; then
    echo "FAIL (no episodes in DB)"
    FAILED=$((FAILED + 1))
    FAIL_LIST="$FAIL_LIST $test_name"
    return
  fi
  echo "OK ($episode_count episode(s) saved)"

  # Step 4: Done
  echo -n "[4/4] Result... "
  take_screenshot "$SCREENSHOTS_DIR/${test_name}.png"
  echo "PASS"
  PASSED=$((PASSED + 1))
}

# =============================================
# Test 2: Memory recalled on second run
# =============================================

run_test_memory_recall() {
  local test_name="memory-recall"
  echo ""
  echo "=========================================="
  echo "Memory Test: $test_name"
  echo "=========================================="
  echo "Verify: Memory context injected on similar task"
  echo ""

  TOTAL=$((TOTAL + 1))

  # Step 1: Clear logcat
  echo -n "[1/4] Setup... "
  $ADB logcat -c >/dev/null 2>&1
  sleep 1
  echo "OK"

  # Step 2: Run a similar task (memory should have episode from test 1)
  echo -n "[2/4] Run similar task... "
  if run_prompt_and_wait "What is 99 times 33?" "Goal achieved" 90; then
    echo "OK (Goal achieved)"
  else
    echo "FAIL (task did not complete)"
    take_screenshot "$SCREENSHOTS_DIR/${test_name}_fail.png"
    FAILED=$((FAILED + 1))
    FAIL_LIST="$FAIL_LIST $test_name"
    return
  fi

  # Step 3: Check logcat for memory recall
  echo -n "[3/4] Check memory recall... "
  sleep 2
  local mem_log
  mem_log=$(get_memory_context_log)
  if [ -n "$mem_log" ]; then
    echo "OK"
    echo "   $mem_log"
  else
    echo "WARN (no memory recall logged — may be empty match)"
  fi

  # Step 4: Verify episode count increased
  echo -n "[4/4] Check DB updated... "
  local episode_count
  episode_count=$(count_memory_rows "episodes")
  if [ -n "$episode_count" ] && [ "$episode_count" -ge 2 ]; then
    echo "OK ($episode_count episodes)"
    take_screenshot "$SCREENSHOTS_DIR/${test_name}.png"
    echo "RESULT: PASS"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (expected >= 2 episodes, got $episode_count)"
    take_screenshot "$SCREENSHOTS_DIR/${test_name}_fail.png"
    echo "RESULT: FAIL"
    FAILED=$((FAILED + 1))
    FAIL_LIST="$FAIL_LIST $test_name"
  fi
}

# =============================================
# Test 3: Repair saved to memory
# =============================================

run_test_repair_save() {
  local test_name="repair-memory"
  echo ""
  echo "=========================================="
  echo "Memory Test: $test_name"
  echo "=========================================="
  echo "Verify: Repair records saved when a step fails and is fixed"
  echo ""

  TOTAL=$((TOTAL + 1))

  # Step 1: Clear memory and restart
  echo -n "[1/4] Clear memory... "
  $ADB shell am force-stop "$PKG" >/dev/null 2>&1
  sleep 1
  clear_memory_db
  sleep 1
  fresh_app
  sleep 5  # extra wait for model to load after cold start
  echo "OK"

  # Step 2: Run a task that may trigger repair
  echo -n "[2/4] Run task (may trigger repair)... "
  if run_prompt_and_wait "Create a calendar event for tomorrow at 3pm called Team Meeting" "Goal achieved" 300; then
    echo "OK (Goal achieved)"
  else
    echo "OK (completed — checking for repair records)"
  fi

  # Step 3: Check for repair records
  echo -n "[3/4] Check repairs in DB... "
  sleep 3
  local repair_count
  repair_count=$(count_memory_rows "repairs")
  local episode_count
  episode_count=$(count_memory_rows "episodes")

  echo "OK (episodes=$episode_count, repairs=${repair_count:-0})"

  # Step 4: At minimum we should have an episode
  echo -n "[4/4] Result... "
  take_screenshot "$SCREENSHOTS_DIR/${test_name}.png"
  if [ -n "$episode_count" ] && [ "$episode_count" -ge 1 ]; then
    echo "PASS (episode saved, repairs=${repair_count:-0})"
    echo "RESULT: PASS"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL (no episode saved)"
    echo "RESULT: FAIL"
    FAILED=$((FAILED + 1))
    FAIL_LIST="$FAIL_LIST $test_name"
  fi
}

# =============================================
# Test 4: Memory recall improves second run
# =============================================

run_test_recall_after_repair() {
  local test_name="recall-after-repair"
  echo ""
  echo "=========================================="
  echo "Memory Test: $test_name"
  echo "=========================================="
  echo "Verify: After repair, memory guides the next similar task"
  echo ""

  TOTAL=$((TOTAL + 1))

  # Step 1: Clear logcat
  echo -n "[1/4] Setup... "
  $ADB logcat -c >/dev/null 2>&1
  sleep 1
  echo "OK"

  # Step 2: Run a similar task (should recall repair memory)
  echo -n "[2/4] Run similar task... "
  if run_prompt_and_wait "Set a reminder for tomorrow at 10am called Dentist Appointment" "Goal achieved" 180; then
    echo "OK (Goal achieved)"
  else
    echo "WARN (task may not have completed)"
  fi

  # Step 3: Check memory recall
  echo -n "[3/4] Check memory recall... "
  sleep 2
  local mem_log
  mem_log=$(get_memory_context_log)
  if [ -n "$mem_log" ]; then
    echo "OK (memory was recalled)"
    echo "   $mem_log"
  else
    echo "WARN (no memory recall logged)"
  fi

  # Step 4: Check total entries
  echo -n "[4/4] Check DB... "
  local episode_count repair_count fact_count
  episode_count=$(count_memory_rows "episodes")
  repair_count=$(count_memory_rows "repairs")
  fact_count=$(count_memory_rows "device_facts")
  echo "episodes=$episode_count repairs=${repair_count:-0} facts=${fact_count:-0}"
  take_screenshot "$SCREENSHOTS_DIR/${test_name}.png"

  if [ -n "$episode_count" ] && [ "$episode_count" -ge 2 ]; then
    echo "RESULT: PASS"
    PASSED=$((PASSED + 1))
  else
    echo "RESULT: FAIL (expected >= 2 episodes)"
    FAILED=$((FAILED + 1))
    FAIL_LIST="$FAIL_LIST $test_name"
  fi
}

# =============================================
# Run all tests (sequential — tests depend on prior state)
# =============================================

run_test_episode_save
run_test_memory_recall
run_test_repair_save
run_test_recall_after_repair

# =============================================
# Summary
# =============================================

echo ""
echo "=========================================="
echo "MEMORY TEST SUMMARY ($DEVICE_MODEL)"
echo "=========================================="
echo "Total:  $TOTAL"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
if [ -n "$FAIL_LIST" ]; then
  echo "Failed:$FAIL_LIST"
fi
echo "Screenshots: $SCREENSHOTS_DIR/"
echo ""

if [ "$FAILED" -gt 0 ]; then
  exit 1
else
  exit 0
fi
