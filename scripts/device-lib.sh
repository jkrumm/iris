# Sourced by scripts/device-*.sh. Resolves the paired phone and the signing team at runtime; neither is ever tracked.
#   IRIS_DEVICE_ID   devicectl identifier or UDID (default: the one connected physical iOS device)
#   DEVICE_SIGNING   paid (default: the paid team, headless with the ASC Team key from op://mini/apple-developer; entitlements as tracked)
#                    | personal (the free Personal Team Xcode knows: no Push/App Groups)
#   TEAM             team id override (default: paid reads `team-id` from the apple-developer item, personal the team Xcode knows)
# Not run on its own; callers `set -euo pipefail` first.

DEVICE_SIGNING="${DEVICE_SIGNING:-paid}"
case "$DEVICE_SIGNING" in
  personal | paid) ;;
  *) echo "  DEVICE_SIGNING must be personal or paid, not '$DEVICE_SIGNING'" >&2; exit 1 ;;
esac
APPLE_DIR="${APPLE_DIR:-apple}"
APP_BUNDLE_ID="com.jkrumm.iris"
ARTIFACTS="${ARTIFACTS:-.artifacts}"

# Exactly one paired, physical iOS device whose tunnel is not unavailable (an idle "disconnected" tunnel comes up on first use), or an error naming IRIS_DEVICE_ID.
device_id() {
  if [ -n "${IRIS_DEVICE_ID:-}" ]; then printf '%s\n' "$IRIS_DEVICE_ID"; return; fi
  local json ids count
  json="$(mktemp)"
  xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || true
  ids="$(jq -r '.result.devices[]? | select(.hardwareProperties.reality == "physical" and .hardwareProperties.platform == "iOS"
    and .connectionProperties.pairingState == "paired" and .connectionProperties.tunnelState != "unavailable") | .identifier' "$json")"
  rm -f "$json"
  count="$(printf '%s' "$ids" | grep -c . || true)"
  if [ "$count" != "1" ]; then
    echo "  found $count reachable paired iPhones (xcrun devicectl list devices); set IRIS_DEVICE_ID=<identifier>" >&2
    return 1
  fi
  printf '%s\n' "$ids"
}

APPLE_DEV_ITEM="op://mini/apple-developer"

# The key as `xcodebuild -authenticationKeyPath` needs it: real newlines, 64-character body lines, whatever shape the value
# arrives in (1Password turns the newlines of a concealed field into spaces; an env file holds a literal \n). Same rule as
# `normalizePem` (server/src/notify/select.ts). Anything that is not one PEM block is printed as given.
pem_normalize() {
  local value label body
  value="$(printf '%s' "$1" | sed 's/\\n/ /g' | tr -s '[:space:]' ' ')"
  label="$(printf '%s' "$value" | sed -nE 's/^ *-----BEGIN ([A-Z0-9 ]+)----- .*/\1/p')"
  if [ -z "$label" ]; then printf '%s\n' "$1"; return; fi
  body="$(printf '%s' "$value" | sed -E "s/^ *-----BEGIN $label----- *//; s/ *-----END $label----- *\$//" | tr -d '[:space:]')"
  printf -- '-----BEGIN %s-----\n%s\n-----END %s-----\n' "$label" "$(printf '%s' "$body" | fold -w 64)" "$label"
}

# Reads one field of the team-wide apple-developer item from the offline secrets cache (never `op`: it hangs on the mini).
apple_dev_field() {
  secrets-run read "$APPLE_DEV_ITEM/$1" || { echo "  secrets-run read $APPLE_DEV_ITEM/$1 failed (make secrets-seed)" >&2; return 1; }
}

# Paid signing without Xcode's account: sets SIGNING_ARGS (xcodebuild flags) and KEY_FILE (a 0600 temp file holding the ASC
# Team key). The caller owns the cleanup: `trap 'rm -f "${KEY_FILE:-}"' EXIT` before calling. No key material reaches argv or a log.
SIGNING_ARGS=()
KEY_FILE=""
paid_signing_setup() {
  local key key_id issuer
  key="$(apple_dev_field asc-key-p8)" || return 1
  key_id="$(apple_dev_field asc-key-id)" || return 1
  issuer="$(apple_dev_field asc-issuer-id)" || return 1
  KEY_FILE="$(mktemp "${TMPDIR:-/tmp}/iris-asc-key.XXXXXX")"
  chmod 600 "$KEY_FILE"
  pem_normalize "$key" >"$KEY_FILE"
  SIGNING_ARGS=(-allowProvisioningUpdates -authenticationKeyPath "$KEY_FILE" -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer")
}

signing_team() {
  if [ -n "${TEAM:-}" ]; then printf '%s\n' "$TEAM"; return; fi
  if [ "$DEVICE_SIGNING" = "paid" ]; then apple_dev_field team-id; return; fi
  local free=true team
  team="$(defaults export com.apple.dt.Xcode - 2>/dev/null | plutil -extract IDEProvisioningTeamByIdentifier json -o - - 2>/dev/null |
    jq -r --argjson free "$free" '[.[][] | select((.isFreeProvisioningTeam // false) == $free)] | first | .teamID // empty' || true)"
  if [ -z "$team" ]; then
    echo "  no $DEVICE_SIGNING team in Xcode (Settings > Accounts); pass TEAM=<id>" >&2
    return 1
  fi
  printf '%s\n' "$team"
}

# A Personal Team signs neither Push nor App Groups (the profile lacks both). Personal builds sign with copies of the tracked
# entitlements minus those keys, derived at build time so they cannot drift; paid signs the tracked files as they are (Push and the
# App Group `group.com.jkrumm.iris`, which the Account Holder registers and enables on the three App IDs in the portal).
# Prints xcodebuild build settings, one per line.
entitlement_settings() {
  local dir name var key dst pair
  [ "$DEVICE_SIGNING" = "personal" ] || return 0
  dir="$(cd "$APPLE_DIR" && pwd)/.dd.noindex/device-entitlements"
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
