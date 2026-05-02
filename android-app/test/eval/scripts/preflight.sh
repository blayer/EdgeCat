#!/usr/bin/env bash
#
# Pre-flight runtime permissions for the EdgeCat eval harness on an
# ADB-connected Android device. Mirrors `scripts/preflight.sh` on iOS
# (which runs `simctl privacy grant` against a simulator). Without these,
# native skills (calendar, contacts, photos, location, ...) hang on the
# permission prompt headlessly.
#
# Usage:
#   android-app/test/eval/scripts/preflight.sh [device-serial]
#
# Same logic as `preflight_permissions()` in run.py — kept as a standalone
# script so it can be invoked once after install, separately from a full
# eval run, and so it parallels the iOS layout.

set -euo pipefail

PKG="com.edgecat.app"
SERIAL="${1:-}"
ADB="${ADB:-/Users/nali/Library/Android/sdk/platform-tools/adb}"
if [[ ! -x "$ADB" ]]; then
    ADB="$(command -v adb || true)"
    if [[ -z "$ADB" ]]; then
        echo "preflight: adb not found (install Android platform-tools)" >&2
        exit 1
    fi
fi

# `adb -s <serial>` only when the caller pinned a device.
if [[ -n "$SERIAL" ]]; then
    ADB_BASE=("$ADB" "-s" "$SERIAL")
else
    ADB_BASE=("$ADB")
fi

# Sanity-check the device is connected.
if ! "${ADB_BASE[@]}" get-state >/dev/null 2>&1; then
    echo "preflight: no device connected (try \`adb devices\`)" >&2
    exit 1
fi

# Sanity-check the app is installed. Headless EvalActivity needs the
# package present before any permission grant makes sense.
if ! "${ADB_BASE[@]}" shell pm list packages 2>/dev/null | grep -q "^package:${PKG}$"; then
    echo "preflight: ${PKG} not installed (run \`./gradlew :app:installDebug\` first)" >&2
    exit 1
fi

# Runtime-dangerous permissions declared in AndroidManifest.xml. EvalActivity
# runs headlessly and cannot surface permission dialogs, so any native skill
# that touches a gated ContentProvider/API would hang until task timeout.
PERMISSIONS=(
    "android.permission.RECORD_AUDIO"
    "android.permission.POST_NOTIFICATIONS"
    "android.permission.SEND_SMS"
    "android.permission.READ_SMS"
    "android.permission.READ_CALENDAR"
    "android.permission.WRITE_CALENDAR"
    "android.permission.READ_CONTACTS"
    "android.permission.READ_MEDIA_IMAGES"
    "android.permission.READ_EXTERNAL_STORAGE"
    "android.permission.CALL_PHONE"
    "android.permission.ACCESS_FINE_LOCATION"
    "android.permission.ACCESS_COARSE_LOCATION"
)

# AppOps grants — `pm grant` doesn't cover these.
APPOPS=(
    "WRITE_SETTINGS"
)

granted=0
skipped=0
for perm in "${PERMISSIONS[@]}"; do
    if out=$("${ADB_BASE[@]}" shell "pm grant ${PKG} ${perm}" 2>&1); then
        if [[ -z "$out" || ( "$out" != *"Exception"* && "$out" != *"Failure"* ) ]]; then
            granted=$((granted + 1))
            continue
        fi
    fi
    # Some permissions only exist on certain API levels (POST_NOTIFICATIONS on
    # 33+, READ_EXTERNAL_STORAGE on <=32). Silently skip — that's expected.
    skipped=$((skipped + 1))
done

for op in "${APPOPS[@]}"; do
    "${ADB_BASE[@]}" shell "appops set ${PKG} ${op} allow" >/dev/null 2>&1 || true
done

echo "preflight: granted ${granted} permissions (${skipped} skipped — n/a on this API)"
