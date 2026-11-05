# Sourced by scripts/testflight.sh (and later device-lib.sh, Wave 21 P1, which defines the same functions today: this file is the
# shared home once both are merged). The App Store Connect Team key and the team id from op://mini/apple-developer, headless.
# Not run on its own; callers `set -euo pipefail` first and install `trap 'rm -f "${KEY_FILE:-}"' EXIT` before paid_signing_setup.

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

# One field of the team-wide apple-developer item from the offline secrets cache (never `op`: it hangs on the mini).
apple_dev_field() {
  secrets-run read "$APPLE_DEV_ITEM/$1" || { echo "  secrets-run read $APPLE_DEV_ITEM/$1 failed (make secrets-seed)" >&2; return 1; }
}

# Sets SIGNING_ARGS (the xcodebuild flags), KEY_FILE (a 0600 temp file holding the key) and ASC_KEY_ID / ASC_ISSUER_ID (for altool).
# The caller owns the cleanup. No key material reaches argv or a log: only the file path, the key id and the issuer id.
SIGNING_ARGS=()
KEY_FILE=""
ASC_KEY_ID=""
ASC_ISSUER_ID=""
paid_signing_setup() {
  local key
  key="$(apple_dev_field asc-key-p8)" || return 1
  ASC_KEY_ID="$(apple_dev_field asc-key-id)" || return 1
  ASC_ISSUER_ID="$(apple_dev_field asc-issuer-id)" || return 1
  KEY_FILE="$(mktemp "${TMPDIR:-/tmp}/iris-asc-key.XXXXXX")"
  chmod 600 "$KEY_FILE"
  pem_normalize "$key" >"$KEY_FILE"
  SIGNING_ARGS=(-allowProvisioningUpdates -authenticationKeyPath "$KEY_FILE" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
}
