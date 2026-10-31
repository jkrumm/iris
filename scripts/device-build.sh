#!/usr/bin/env bash
# Signed Debug build of Iris (+ widgets and notification extension) for the paired iPhone -> apple/.dd.noindex/Build/Products/Debug-iphoneos/Iris.app.
# The first run registers the device with the team (-allowProvisioningUpdates). A codesign key prompt on the mini's screen needs "Always Allow".
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/device-lib.sh

dev="$(device_id)"
team="$(signing_team)"
ent="$(entitlement_settings)"  # build settings, one per line; paths hold no spaces
echo "  device build: signing=$DEVICE_SIGNING team=<resolved> entitlement overrides=$(printf %s "$ent" | grep -c .)"
xcodebuild -project "$APPLE_DIR/Iris.xcodeproj" -scheme Iris -configuration Debug -derivedDataPath "$APPLE_DIR/.dd.noindex" \
  -destination "id=$dev" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$team" IRIS_BUILD_SHA="$(git rev-parse --short HEAD)" $ent build
