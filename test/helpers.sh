#!/bin/bash
# Shared ADB/UI helpers for Mobile-Claw on-device tests.
# Ensure ADB is on PATH
export PATH="$PATH:$HOME/Library/Android/sdk/platform-tools"
# Sourced by device.sh, orchestration.sh, etc.
#
# Expects these variables to be set by the caller:
#   ADB          — "adb" or "adb -s <serial>"
#   UI_XML       — path where uiautomator XML dumps are stored
#   SKILL_NAME   — skill folder name (for import_skill)
#   SKILL_PATH   — local path to skill folder (for import_skill)

# Mobile-Claw package/activity
PKG="com.mobileclaw.app"
ACTIVITY="com.mobileclaw.app.MobileClawActivity"

# =============================================
# Low-level ADB helpers
# =============================================

dump_ui() {
  $ADB shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  $ADB pull /sdcard/ui.xml "$UI_XML" >/dev/null 2>&1
}

take_screenshot() {
  local dest="${1:-/tmp/screenshot.png}"
  $ADB shell screencap -p /sdcard/screenshot.png >/dev/null 2>&1
  $ADB pull /sdcard/screenshot.png "$dest" >/dev/null 2>&1
}

# Check if UI contains text (substring match, case-insensitive)
ui_has() {
  python3 -c "
import xml.etree.ElementTree as ET, sys, os
if not os.path.exists('$UI_XML') or os.path.getsize('$UI_XML') == 0:
    sys.exit(1)
try:
    tree = ET.parse('$UI_XML')
except ET.ParseError:
    sys.exit(1)
target = '''$1'''.lower()
for node in tree.iter('node'):
    t = node.get('text', '').lower()
    cd = node.get('content-desc', '').lower()
    if target in t or target in cd:
        sys.exit(0)
sys.exit(1)
"
}

# Extract all visible text from UI dump
ui_text() {
  python3 -c "
import xml.etree.ElementTree as ET, os, sys
if not os.path.exists('$UI_XML') or os.path.getsize('$UI_XML') == 0:
    sys.exit(0)
try:
    tree = ET.parse('$UI_XML')
except ET.ParseError:
    sys.exit(0)
seen = set()
for node in tree.iter('node'):
    t = node.get('text', '').strip()
    if t and t not in seen:
        seen.add(t)
        print(t)
"
}

# Find center coordinates of a UI element by text
find_element() {
  python3 -c "
import xml.etree.ElementTree as ET, re, sys, os
if not os.path.exists('$UI_XML') or os.path.getsize('$UI_XML') == 0:
    sys.exit(1)
try:
    tree = ET.parse('$UI_XML')
except ET.ParseError:
    sys.exit(1)
target = '''$1'''
for node in tree.iter('node'):
    t = node.get('text', '')
    cd = node.get('content-desc', '')
    if t == target or cd == target:
        m = re.findall(r'\d+', node.get('bounds', ''))
        if len(m) == 4:
            print(f'{(int(m[0])+int(m[2]))//2} {(int(m[1])+int(m[3]))//2}')
            sys.exit(0)
sys.exit(1)
"
}

# Find element by partial text match
find_element_partial() {
  python3 -c "
import xml.etree.ElementTree as ET, re, sys, os
if not os.path.exists('$UI_XML') or os.path.getsize('$UI_XML') == 0:
    sys.exit(1)
try:
    tree = ET.parse('$UI_XML')
except ET.ParseError:
    sys.exit(1)
target = '''$1'''.lower()
for node in tree.iter('node'):
    t = node.get('text', '').lower()
    cd = node.get('content-desc', '').lower()
    if target in t or target in cd:
        m = re.findall(r'\d+', node.get('bounds', ''))
        if len(m) == 4:
            print(f'{(int(m[0])+int(m[2]))//2} {(int(m[1])+int(m[3]))//2}')
            sys.exit(0)
sys.exit(1)
"
}

# Tap a UI element by exact text
tap_element() {
  dump_ui
  local coords
  coords=$(find_element "$1")
  if [ -z "$coords" ]; then
    # Try partial match
    coords=$(find_element_partial "$1")
  fi
  if [ -z "$coords" ]; then
    return 1
  fi
  $ADB shell input tap $coords
  sleep 0.5
  return 0
}

# Tap a UI element by partial text match
tap_element_partial() {
  dump_ui
  local coords
  coords=$(find_element_partial "$1")
  if [ -z "$coords" ]; then
    return 1
  fi
  $ADB shell input tap $coords
  sleep 0.5
  return 0
}

# Tap at raw coordinates
tap_xy() {
  $ADB shell input tap "$1" "$2"
  sleep 0.3
}

# =============================================
# Text input
# =============================================

# Type text via ADB (handles spaces)
type_text() {
  local escaped
  escaped=$(echo "$1" | sed 's/ /%s/g; s/[&|;$`"'"'"'\\<>()!#*?{}]/\\&/g')
  $ADB shell input text "$escaped"
}

# Press Enter/IME Send
press_enter() {
  $ADB shell input keyevent 66
}

# Clear the input field (select all + delete)
clear_input() {
  $ADB shell input keyevent KEYCODE_MOVE_END
  for i in $(seq 1 100); do
    $ADB shell input keyevent KEYCODE_DEL
  done
}

# =============================================
# App lifecycle
# =============================================

# Force-stop and cold-start the app, then navigate to chat
fresh_app() {
  $ADB shell am force-stop "$PKG" >/dev/null 2>&1
  sleep 2
  $ADB shell am start -n "$PKG/$ACTIVITY" >/dev/null 2>&1
  sleep 5

  # Wait for any screen to appear
  local waited=0
  while [ $waited -lt 30 ]; do
    dump_ui
    if ui_has "Type prompt" || ui_has "Prompt input" || ui_has "Try it" || ui_has "Start" || ui_has "Agent Skills" || ui_has "Choose a model"; then
      break
    fi
    sleep 3
    waited=$((waited + 3))
  done

  # If on model select screen, navigate to chat
  dump_ui
  if ! ui_has "Type prompt" && ! ui_has "Prompt input"; then
    navigate_to_chat
  fi
}

# Ensure we're on the chat screen without restarting the app if possible
warm_start() {
  dump_ui
  if ui_has "Type prompt" || ui_has "Prompt input"; then
    return 0
  fi
  # Not on chat screen — try launching activity
  $ADB shell am start -n "$PKG/$ACTIVITY" >/dev/null 2>&1
  sleep 3
  dump_ui
  if ui_has "Type prompt" || ui_has "Prompt input"; then
    return 0
  fi
  # Still not on chat, do full fresh start
  fresh_app
}

# Navigate to chat: if on model select screen, tap "Try it" on first available model
navigate_to_chat() {
  dump_ui
  if ui_has "Start"; then
    tap_element "Start"
    sleep 5
    dump_ui
  elif ui_has "Try it"; then
    tap_element "Try it"
    sleep 5
    dump_ui
  fi
  # Wait for chat screen (model may take up to 60s to initialize)
  local waited=0
  while [ $waited -lt 60 ]; do
    dump_ui
    if ui_has "Type prompt" || ui_has "Prompt input"; then
      # Wait for model to finish initializing
      local init_wait=0
      while [ $init_wait -lt 60 ]; do
        dump_ui
        if ! ui_has "Initializing"; then
          return 0
        fi
        sleep 5
        init_wait=$((init_wait + 5))
      done
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

# Reset chat session (start new conversation)
reset_session() {
  # Look for "New chat" or "Reset" button
  dump_ui
  tap_element "New chat" 2>/dev/null || tap_element "Reset" 2>/dev/null || true
  sleep 1
}

# =============================================
# Skill management
# =============================================

# Import a skill from /sdcard/Download/$SKILL_NAME
import_skill() {
  echo -n "(importing $SKILL_NAME) "

  # Open skills panel
  dump_ui
  tap_element "Skills"
  sleep 1

  # Tap add button
  dump_ui
  if ! tap_element "Add" && ! tap_element "+"; then
    # Try content-desc based
    tap_element "Add skill"
  fi
  sleep 1

  # Tap "Import local skill"
  dump_ui
  tap_element "Import local skill" || tap_element "Import from device"
  sleep 2

  # Navigate to Download folder and select skill
  dump_ui
  if ui_has "Download"; then
    tap_element "Download"
    sleep 1
  fi

  dump_ui
  if ui_has "$SKILL_NAME"; then
    tap_element "$SKILL_NAME"
    sleep 1
    # Confirm selection if needed
    dump_ui
    tap_element "USE THIS FOLDER" 2>/dev/null || tap_element "Select" 2>/dev/null || true
    sleep 1
  fi

  # Close skills panel
  dump_ui
  tap_element "Close" 2>/dev/null || $ADB shell input keyevent KEYCODE_BACK
  sleep 1
}

# =============================================
# Prompt & polling
# =============================================

# Send a chat prompt
send_prompt() {
  local prompt="$1"
  dump_ui

  # Find and tap the input field
  if ! tap_element "Type prompt"; then
    tap_element "Prompt input" || tap_element_partial "prompt"
  fi
  sleep 0.5

  # Type the prompt
  type_text "$prompt"
  sleep 0.3

  # Send (tap send button or press Enter)
  dump_ui
  if ! tap_element "Send"; then
    press_enter
  fi
  sleep 1
}

# Poll UI for a text pattern with timeout.
# Detects early completion: if the UI hasn't changed for 3 consecutive
# polls, the app is done and the pattern won't appear — fail immediately
# instead of waiting for the full timeout.
#
# Usage: poll_ui "pattern" timeout_seconds poll_interval_seconds
poll_ui() {
  local pattern="$1"
  local timeout="${2:-60}"
  local interval="${3:-3}"
  local elapsed=0
  local stale_count=0
  local prev_hash=""

  while [ $elapsed -lt $timeout ]; do
    dump_ui

    # Check for success
    if ui_has "$pattern"; then
      return 0
    fi

    # Detect stale UI — hash all visible text. If unchanged for 3 polls
    # (~15s with default interval), the app has settled without the
    # success pattern appearing.
    local cur_hash
    cur_hash=$(ui_text | md5 2>/dev/null || ui_text | md5sum 2>/dev/null | cut -d' ' -f1)
    if [ -n "$prev_hash" ] && [ "$cur_hash" = "$prev_hash" ]; then
      stale_count=$((stale_count + 1))
      if [ $stale_count -ge 3 ]; then
        return 1  # UI settled, pattern not found
      fi
    else
      stale_count=0
      prev_hash="$cur_hash"
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  return 1
}

# =============================================
# Scroll helpers
# =============================================

scroll_down() {
  local screen_height
  screen_height=$($ADB shell wm size 2>/dev/null | grep -o '[0-9]*x[0-9]*' | tail -1 | cut -dx -f2)
  screen_height=${screen_height:-2340}
  local mid_x=$(( $($ADB shell wm size 2>/dev/null | grep -o '[0-9]*x[0-9]*' | tail -1 | cut -dx -f1) / 2 ))
  mid_x=${mid_x:-540}
  local from_y=$((screen_height * 3 / 4))
  local to_y=$((screen_height / 4))
  $ADB shell input swipe $mid_x $from_y $mid_x $to_y 300
  sleep 0.5
}

scroll_up() {
  local screen_height
  screen_height=$($ADB shell wm size 2>/dev/null | grep -o '[0-9]*x[0-9]*' | tail -1 | cut -dx -f2)
  screen_height=${screen_height:-2340}
  local mid_x=$(( $($ADB shell wm size 2>/dev/null | grep -o '[0-9]*x[0-9]*' | tail -1 | cut -dx -f1) / 2 ))
  mid_x=${mid_x:-540}
  local from_y=$((screen_height / 4))
  local to_y=$((screen_height * 3 / 4))
  $ADB shell input swipe $mid_x $from_y $mid_x $to_y 300
  sleep 0.5
}

# Scroll up from very bottom of the screen (useful for chat)
scroll_up_from_bottom() {
  local screen_height
  screen_height=$($ADB shell wm size 2>/dev/null | grep -o '[0-9]*x[0-9]*' | tail -1 | cut -dx -f2)
  screen_height=${screen_height:-2340}
  local mid_x=$(( $($ADB shell wm size 2>/dev/null | grep -o '[0-9]*x[0-9]*' | tail -1 | cut -dx -f1) / 2 ))
  mid_x=${mid_x:-540}
  local from_y=$((screen_height * 9 / 10))
  local to_y=$((screen_height / 5))
  $ADB shell input swipe $mid_x $from_y $mid_x $to_y 400
  sleep 0.5
}

# =============================================
# Count & poll-by-count helpers
# =============================================

# Count occurrences of text in UI dump
ui_count() {
  python3 -c "
import xml.etree.ElementTree as ET
tree = ET.parse('$UI_XML')
target = '''$1'''.lower()
count = 0
for node in tree.iter('node'):
    t = node.get('text', '').lower()
    if target in t:
        count += 1
print(count)
"
}

# Poll until ui_count for pattern reaches at least N
# Usage: poll_ui_count "pattern" min_count timeout_seconds interval_seconds
poll_ui_count() {
  local pattern="$1"
  local min_count="$2"
  local timeout="${3:-60}"
  local interval="${4:-3}"
  local elapsed=0

  while [ $elapsed -lt $timeout ]; do
    dump_ui
    local current
    current=$(ui_count "$pattern")
    if [ "$current" -ge "$min_count" ] 2>/dev/null; then
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  return 1
}

# =============================================
# App install helper
# =============================================

# Ensure app is installed (no-op if APK path is empty)
ensure_app_installed() {
  local apk="$1"
  if [ -z "$apk" ] || [ ! -f "$apk" ]; then
    # Check if already installed
    if $ADB shell pm list packages 2>/dev/null | grep -q "$PKG"; then
      echo "[Setup] App already installed"
    else
      echo "[Setup] WARNING: App not installed and no APK provided"
    fi
    return 0
  fi
  echo -n "[Setup] Installing APK... "
  $ADB install -r "$apk" >/dev/null 2>&1
  echo "OK"
}
