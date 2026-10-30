#!/usr/bin/env bash
# Runs RouteConfigReviewUITests on the pinned simulator and exports its screenshots to .artifacts/route-config/<step>-<appearance>.png.
set -euo pipefail
cd "$(dirname "$0")/.."

out=.artifacts/route-config
bundle=.artifacts/route-config.xcresult
rm -rf "$out" "$bundle"
mkdir -p "$out"

make generate >/dev/null
make sim >/dev/null
xcodebuild -project apple/Iris.xcodeproj -scheme Iris -derivedDataPath apple/.dd CODE_SIGNING_ALLOWED=NO \
  -destination "platform=iOS Simulator,name=${SIM_NAME:-iPhone 17},OS=${SIM_OS:-27.0}" \
  -resultBundlePath "$bundle" -only-testing:IrisUITests/RouteConfigReviewUITests test

raw=$(mktemp -d)
xcrun xcresulttool export attachments --path "$bundle" --output-path "$raw"
# manifest.json maps the exported file names to the attachment names set in the test.
jq -r '.[].attachments[] | select(.suggestedHumanReadableName | startswith("route-config-")) | "\(.exportedFileName)\t\(.suggestedHumanReadableName)"' "$raw/manifest.json" |
  while IFS=$'\t' read -r file name; do
    clean=${name#route-config-}
    clean=${clean%%_[0-9]*}
    cp "$raw/$file" "$out/$clean.png"
  done
rm -rf "$raw"
ls "$out"
