#!/usr/bin/env bash
#
# Pre-flight permissions for the EdgeCat eval harness on a simulator.
# Mirrors `pm grant` block in android-app/test/eval/run.py — without these,
# native skills (calendar, contacts, photos, location, …) hang on the
# permission prompt headlessly.
#
# Usage:
#   ios-app-wip/test/eval/scripts/preflight.sh <simulator-udid> [bundle-id]
#
# `xcrun simctl privacy grant` works on simulators only — real devices
# need user-driven permission grants once.

set -euo pipefail

# `simctl` lives under the full Xcode developer dir, not the Command Line
# Tools dir most contributors get from `xcode-select`. Force the right
# one for this script's lifetime.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

UDID="${1:?simulator UDID required (xcrun simctl list devices)}"
BUNDLE_ID="${2:-com.edgecat.app}"

# Sanity-check the simulator exists.
if ! xcrun simctl list devices -j | grep -q "\"udid\" : \"$UDID\""; then
    echo "preflight: simulator UDID not found: $UDID" >&2
    exit 1
fi

services=(
    calendar
    contacts
    photos-add
    photos
    location
    location-always
    microphone
    camera
    reminders
    motion
)

for service in "${services[@]}"; do
    # `simctl privacy grant` is a no-op for services not relevant to this
    # bundle (e.g. media-library), so we just blast all of them.
    xcrun simctl privacy "$UDID" grant "$service" "$BUNDLE_ID" \
        2>/dev/null || true
done

# Push a deterministic GPS fix into the simulator so CoreLocation has
# something to deliver. Without this, `CLLocationManager.requestLocation`
# can sit silently for the whole 5–8s skill timeout. Apple Park
# (Cupertino) matches the `directions-walk-001` task's coffee-shop
# expectation per dataset notes.
xcrun simctl location "$UDID" set 37.3349,-122.0090 2>/dev/null || true

echo "preflight: granted ${#services[@]} privacy services + set GPS to Apple Park on $BUNDLE_ID/$UDID"
