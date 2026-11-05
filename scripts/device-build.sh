#!/usr/bin/env bash
# Signed Debug build of Iris (+ widgets and notification extension) for the paired iPhone -> apple/.dd.noindex/Build/Products/Debug-iphoneos/Iris.app.
# DEVICE_SIGNING=paid (default): the paid team, headless. Team id and the App Store Connect Team key come from op://mini/apple-developer via
# secrets-run; the key is written to a 0600 temp file for -authenticationKeyPath and deleted on every exit. DEVICE_SIGNING=personal: the free
# Personal Team from Xcode's account (-allowProvisioningUpdates, no key). The first run registers the device with the team.
# A codesign key prompt on the mini's screen needs "Always Allow".
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/device-lib.sh

dev="$(device_id)"
team="$(signing_team)"
trap 'rm -f "${KEY_FILE:-}"' EXIT
if [ "$DEVICE_SIGNING" = "paid" ]; then
  paid_signing_setup
else
  SIGNING_ARGS=(-allowProvisioningUpdates)
fi
ent="$(entitlement_settings)"  # build settings, one per line; paths hold no spaces
echo "  device build: signing=$DEVICE_SIGNING team=<resolved> entitlement overrides=$(printf %s "$ent" | grep -c .)"
xcodebuild -project "$APPLE_DIR/Iris.xcodeproj" -scheme Iris -configuration Debug -derivedDataPath "$APPLE_DIR/.dd.noindex" \
  -destination "id=$dev" "${SIGNING_ARGS[@]}" \
  DEVELOPMENT_TEAM="$team" IRIS_BUILD_SHA="$(git rev-parse --short HEAD)" $ent build
