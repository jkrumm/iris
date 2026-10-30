#!/usr/bin/env bash
# Full-resolution PNG of the paired iPhone -> .artifacts/<name>.png (first argument, default device-<time>) via devicectl.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/device-lib.sh

dev="$(device_id)"
mkdir -p "$ARTIFACTS"
out="$ARTIFACTS/${1:-device-$(date +%H%M%S)}.png"
xcrun devicectl device capture screenshot --device "$dev" --destination "$out" >/dev/null
echo "  $out"
