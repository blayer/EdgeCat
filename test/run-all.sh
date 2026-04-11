#!/bin/bash
# Mobile-Claw: Unified Test Runner
# Runs all 3 test levels in order. Stops on first failure.
#
# Usage: ./test/run-all.sh [-d <device-serial>] [--skip-device]
#
# Levels:
#   1. Unit tests       — individual function tests (no device)
#   2. Integration tests — end-to-end flow simulations (no device)
#   3. On-device tests   — real scenarios on physical device (ADB + device + model)
#
# Every change must pass all 3 levels before merging.

set -e

# Android SDK & JDK setup
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [ -z "$JAVA_HOME" ]; then
  if [ -d "/Applications/Android Studio.app/Contents/jbr/Contents/Home" ]; then
    export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  fi
fi
export PATH="${JAVA_HOME:+$JAVA_HOME/bin:}$PATH:$ANDROID_HOME/platform-tools"

DEVICE_SERIAL=""
SKIP_DEVICE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    -d) DEVICE_SERIAL="$2"; shift 2 ;;
    --skip-device) SKIP_DEVICE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [-d <device-serial>] [--skip-device]"
      echo ""
      echo "Options:"
      echo "  -d <serial>    Device serial for Level 3 (default: first connected device)"
      echo "  --skip-device  Skip Level 3 (on-device tests)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TOTAL_LEVELS=3
if [ "$SKIP_DEVICE" = true ]; then
  TOTAL_LEVELS=2
fi

echo "=========================================="
echo "Mobile-Claw Test Runner"
echo "=========================================="
echo "Levels to run: $TOTAL_LEVELS"
echo ""

# ─── Level 1: Unit Tests ───

echo "=========================================="
echo "LEVEL 1: Unit Tests"
echo "=========================================="
echo ""

cd "$PROJECT_DIR"
if ./gradlew testDebugUnitTest \
  --tests "com.mobileclaw.app.orchestration.*" \
  --tests "com.mobileclaw.app.customtasks.*" \
  --no-daemon -q 2>&1; then
  echo ""
  echo "LEVEL 1: PASS"
else
  echo ""
  echo "LEVEL 1: FAIL"
  echo "Fix unit tests before proceeding."
  exit 1
fi

echo ""

# ─── Level 2: Integration Tests ───

echo "=========================================="
echo "LEVEL 2: Integration Tests"
echo "=========================================="
echo ""

cd "$PROJECT_DIR"
if ./gradlew testDebugUnitTest \
  --tests "com.mobileclaw.app.integration.*" \
  --no-daemon -q 2>&1; then
  echo ""
  echo "LEVEL 2: PASS"
else
  echo ""
  echo "LEVEL 2: FAIL"
  echo "Fix integration tests before proceeding."
  exit 1
fi

echo ""

# ─── Level 3: On-Device Tests ───

if [ "$SKIP_DEVICE" = true ]; then
  echo "=========================================="
  echo "LEVEL 3: On-Device Tests (SKIPPED)"
  echo "=========================================="
  echo ""
else
  echo "=========================================="
  echo "LEVEL 3: On-Device Tests"
  echo "=========================================="
  echo ""

  DEVICE_ARG=""
  if [ -n "$DEVICE_SERIAL" ]; then
    DEVICE_ARG="-d $DEVICE_SERIAL"
  fi

  # Run all orchestration scenarios on device
  if "$SCRIPT_DIR/orchestration.sh" $DEVICE_ARG; then
    echo ""
    echo "LEVEL 3: PASS"
  else
    echo ""
    echo "LEVEL 3: FAIL"
    echo "Fix on-device tests before merging."
    exit 1
  fi
fi

echo ""

# ─── Summary ───

echo "=========================================="
echo "ALL LEVELS PASSED ($TOTAL_LEVELS/$TOTAL_LEVELS)"
echo "=========================================="
