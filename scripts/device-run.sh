#!/usr/bin/env bash
# Installs the device build on the paired iPhone, launches it (extra args go to the app) and screenshots the phone to .artifacts/.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/device-lib.sh

dev="$(device_id)"
app="$APPLE_DIR/.dd/Build/Products/Debug-iphoneos/Iris.app"
[ -d "$app" ] || { echo "  $app missing: run scripts/device-build.sh (make device-build)" >&2; exit 1; }
xcrun devicectl device install app --device "$dev" "$app"
xcrun devicectl device process launch --device "$dev" --terminate-existing "$APP_BUNDLE_ID" "$@"
sleep "${DEVICE_SETTLE:-4}"
scripts/device-screenshot.sh
