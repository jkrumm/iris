# Sourced by scripts/device-*.sh. Resolves the paired phone and the signing team at runtime; neither is ever tracked.
#   IRIS_DEVICE_ID   devicectl identifier or UDID (default: the one connected physical iOS device)
#   DEVICE_SIGNING   personal (default, free Personal Team: no Push) | paid (the paid team: aps-environment kept)
#   TEAM             team id override (default: the Personal or the paid team Xcode knows, by DEVICE_SIGNING)
# Not run on its own; callers `set -euo pipefail` first.

DEVICE_SIGNING="${DEVICE_SIGNING:-personal}"
APPLE_DIR="${APPLE_DIR:-apple}"
APP_BUNDLE_ID="com.jkrumm.iris"
ARTIFACTS="${ARTIFACTS:-.artifacts}"

device_id() {
  if [ -n "${IRIS_DEVICE_ID:-}" ]; then printf '%s\n' "$IRIS_DEVICE_ID"; return; fi
  local json id
  json="$(mktemp)"
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || true
  id="$(jq -r '[.result.devices[]? | select(.hardwareProperties.reality == "physical" and .hardwareProperties.platform == "iOS"
    and .connectionProperties.pairingState == "paired")] | first | .identifier // empty' "$json")"
  rm -f "$json"
  [ -n "$id" ] || { echo "  no paired physical iPhone (xcrun devicectl list devices); set IRIS_DEVICE_ID" >&2; return 1; }
  printf '%s\n' "$id"
}

signing_team() {
  if [ -n "${TEAM:-}" ]; then printf '%s\n' "$TEAM"; return; fi
  local want="false" team
  [ "$DEVICE_SIGNING" = "paid" ] && want="true"
  team="$(defaults export com.apple.dt.Xcode - 2>/dev/null | plutil -extract IDEProvisioningTeamByIdentifier json -o - - 2>/dev/null |
    jq -r --argjson free "$([ "$want" = true ] && echo false || echo true)" \
      '[.[][] | select((.isFreeProvisioningTeam // false) == $free)] | first | .teamID // empty')"
  [ -n "$team" ] || { echo "  no $DEVICE_SIGNING team in Xcode (Settings > Accounts); pass TEAM=<id>" >&2; return 1; }
  printf '%s\n' "$team"
}

# A Personal Team signs neither Push nor App Groups (the profile lacks both; no Swift code uses the group yet). Personal builds
# sign with copies of the tracked entitlements minus those keys, derived at build time so they cannot drift; paid keeps the files.
# Prints xcodebuild build settings, one per line.
entitlement_settings() {
  local dir name var key dst
  dir="$(cd "$APPLE_DIR" && pwd)/.dd/personal-entitlements"
  for pair in "Iris:IRIS_APP_ENTITLEMENTS" "IrisWidgets:IRIS_WIDGETS_ENTITLEMENTS" "IrisNotifications:IRIS_NOTIFICATIONS_ENTITLEMENTS"; do
    name="${pair%%:*}"; var="${pair##*:}"
    if [ "$DEVICE_SIGNING" = "paid" ]; then continue; fi
    mkdir -p "$dir"
    dst="$dir/$name.entitlements"
    cp "$APPLE_DIR/$name/$name.entitlements" "$dst"
    for key in aps-environment com.apple.security.application-groups; do /usr/libexec/PlistBuddy -c "Delete :$key" "$dst" 2>/dev/null || true; done
    printf '%s=%s\n' "$var" "$dst"
  done
}
