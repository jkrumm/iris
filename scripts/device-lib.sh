# Sourced by scripts/device-*.sh. Resolves the paired phone and the signing team at runtime; neither is ever tracked.
#   IRIS_DEVICE_ID   devicectl identifier or UDID (default: the one connected physical iOS device)
#   DEVICE_SIGNING   personal (default, free Personal Team: no Push/App Groups) | paid (the paid team: entitlements as tracked)
#   TEAM             team id override (default: the Personal or the paid team Xcode knows, by DEVICE_SIGNING)
# Not run on its own; callers `set -euo pipefail` first.

DEVICE_SIGNING="${DEVICE_SIGNING:-personal}"
case "$DEVICE_SIGNING" in
  personal | paid) ;;
  *) echo "  DEVICE_SIGNING must be personal or paid, not '$DEVICE_SIGNING'" >&2; exit 1 ;;
esac
APPLE_DIR="${APPLE_DIR:-apple}"
APP_BUNDLE_ID="com.jkrumm.iris"
ARTIFACTS="${ARTIFACTS:-.artifacts}"

# Exactly one paired, physical iOS device with a live tunnel, or an error naming IRIS_DEVICE_ID.
device_id() {
  if [ -n "${IRIS_DEVICE_ID:-}" ]; then printf '%s\n' "$IRIS_DEVICE_ID"; return; fi
  local json ids count
  json="$(mktemp)"
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || true
  ids="$(jq -r '.result.devices[]? | select(.hardwareProperties.reality == "physical" and .hardwareProperties.platform == "iOS"
    and .connectionProperties.pairingState == "paired" and .connectionProperties.tunnelState == "connected") | .identifier' "$json")"
  rm -f "$json"
  count="$(printf '%s' "$ids" | grep -c . || true)"
  if [ "$count" != "1" ]; then
    echo "  found $count connected paired iPhones (xcrun devicectl list devices); set IRIS_DEVICE_ID=<identifier>" >&2
    return 1
  fi
  printf '%s\n' "$ids"
}

signing_team() {
  if [ -n "${TEAM:-}" ]; then printf '%s\n' "$TEAM"; return; fi
  local free=true team
  [ "$DEVICE_SIGNING" = "paid" ] && free=false
  team="$(defaults export com.apple.dt.Xcode - 2>/dev/null | plutil -extract IDEProvisioningTeamByIdentifier json -o - - 2>/dev/null |
    jq -r --argjson free "$free" '[.[][] | select((.isFreeProvisioningTeam // false) == $free)] | first | .teamID // empty' || true)"
  if [ -z "$team" ]; then
    echo "  no $DEVICE_SIGNING team in Xcode (Settings > Accounts); pass TEAM=<id>" >&2
    return 1
  fi
  printf '%s\n' "$team"
}

# A Personal Team signs neither Push nor App Groups (the profile lacks both; no Swift code uses the group yet). Personal builds
# sign with copies of the tracked entitlements minus those keys, derived at build time so they cannot drift; paid keeps the files.
# Prints xcodebuild build settings, one per line.
entitlement_settings() {
  local dir name var key dst pair
  [ "$DEVICE_SIGNING" = "paid" ] && return 0
  dir="$(cd "$APPLE_DIR" && pwd)/.dd.noindex/personal-entitlements"
  mkdir -p "$dir"
  for pair in "Iris:IRIS_APP_ENTITLEMENTS" "IrisWidgets:IRIS_WIDGETS_ENTITLEMENTS" "IrisNotifications:IRIS_NOTIFICATIONS_ENTITLEMENTS"; do
    name="${pair%%:*}"; var="${pair##*:}"
    dst="$dir/$name.entitlements"
    cp "$APPLE_DIR/$name/$name.entitlements" "$dst"
    for key in aps-environment com.apple.security.application-groups; do
      if /usr/libexec/PlistBuddy -c "Print :$key" "$dst" >/dev/null 2>&1; then /usr/libexec/PlistBuddy -c "Delete :$key" "$dst"; fi
    done
    printf '%s=%s\n' "$var" "$dst"
  done
}
