#!/usr/bin/env bash
# Builds, signs and publishes a Sparkle release of the Mac app (TDD §5 "Updates"): `make mac-release IDENTITY=... [PUBLISH=...]`.
#
#   IDENTITY=development   Apple Development signature of the paid team, no notarization. For the pipeline proof; a draft only.
#   IDENTITY=developer-id  Developer ID Application signature, notarized and stapled with the ASC Team key. Needs the certificate
#                          (with its private key) in the login keychain: the Account Holder creates it, not this script.
#   PUBLISH=draft          a draft GitHub release: `releases/latest` never serves it (default for development)
#   PUBLISH=release        a published release: every installed app finds it (default for developer-id; needs a clean tree
#                          and a HEAD that is on origin)
#
# Steps: xcodegen, archive IrisMac (Release, CURRENT_PROJECT_VERSION = `git rev-list --count HEAD`), check the signature (team,
# Hardened Runtime, audio-input, no sandbox), [notarize + staple], ditto zip, appcast through `generate_appcast`, verify the
# appcast's EdDSA signature against the zip, `gh release create` with the zip + appcast.xml. Nothing is written back to the repo.
#
# Secrets (never in argv or a log): team id and the ASC Team key from op://mini/apple-developer via secrets-run (never `op`),
# the Sparkle EdDSA key from SPARKLE_KEY_FILE (default ~/.local/state/apple-developer/sparkle-ed25519.key, `generate_keys -x`):
# `sign_update` and `generate_appcast` hang on the login keychain's access prompt when run headless, so the key file is the path.
# The GitHub token is the mini's (op://mini/github/token) unless GH_TOKEN is set.
# Run under the lock like every xcodebuild: `lockf -t 1800 /tmp/iris-apple.lock timeout 2400 make mac-release ...`.
#
# SIGNING_ONLY=1 stops after the signature check (no zip, no release). Mirrors P1's scripts/device-lib.sh helpers (pem_normalize,
# apple_dev_field, paid_signing_setup); fold them into one library when both are on master.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${IDENTITY:-}"
case "$IDENTITY" in
  development) PUBLISH="${PUBLISH:-draft}" ;;
  developer-id) PUBLISH="${PUBLISH:-release}" ;;
  *) echo "  IDENTITY must be development or developer-id (make mac-release IDENTITY=development)" >&2; exit 1 ;;
esac
case "$PUBLISH" in
  draft | release) ;;
  *) echo "  PUBLISH must be draft or release, not '$PUBLISH'" >&2; exit 1 ;;
esac
if [ "$IDENTITY" = "development" ] && [ "$PUBLISH" = "release" ]; then
  echo "  refusing: a development-signed, un-notarized build must not become releases/latest (use PUBLISH=draft)" >&2
  exit 1
fi

REPO="${RELEASE_REPO:-jkrumm/iris}"
APPLE_DIR="${APPLE_DIR:-apple}"
APPLE_DEV_ITEM="op://mini/apple-developer"
SPARKLE_KEY_FILE="${SPARKLE_KEY_FILE:-$HOME/.local/state/apple-developer/sparkle-ed25519.key}"
BUILD="$(git rev-list --count HEAD)"
SHA="$(git rev-parse HEAD)"
WORK="$PWD/.artifacts/mac-release/$BUILD"
ARCHIVE="$WORK/IrisMac.xcarchive"
UPLOAD="$WORK/upload"
DERIVED="$PWD/$APPLE_DIR/.dd.noindex"

for tool in xcodebuild xcodegen codesign ditto jq secrets-run xcrun; do
  command -v "$tool" >/dev/null || { echo "  missing tool: $tool" >&2; exit 1; }
done
[ -r "$SPARKLE_KEY_FILE" ] || { echo "  no Sparkle EdDSA key file at $SPARKLE_KEY_FILE (generate_keys -x <file>, or SPARKLE_KEY_FILE=)" >&2; exit 1; }
if [ "$PUBLISH" = "release" ]; then
  [ -z "$(git status --porcelain)" ] || { echo "  refusing a release from a dirty tree" >&2; exit 1; }
  [ -n "$(git branch -r --contains "$SHA" 2>/dev/null)" ] || { echo "  refusing a release: HEAD is not on origin (push first)" >&2; exit 1; }
fi

KEY_FILE=""
cleanup() { [ -z "$KEY_FILE" ] || rm -f "$KEY_FILE"; }
trap cleanup EXIT

# --- secrets -------------------------------------------------------------------------------------------------------------

# The key as xcodebuild / notarytool need it: real newlines, 64-character body lines, whatever shape the value arrives in
# (1Password turns the newlines of a concealed field into spaces; an env file holds a literal \n). Same rule as `normalizePem`
# (server/src/notify/select.ts). Anything that is not one PEM block is printed as given.
pem_normalize() {
  local value label body
  value="$(printf '%s' "$1" | sed 's/\\n/ /g' | tr -s '[:space:]' ' ')"
  label="$(printf '%s' "$value" | sed -nE 's/^ *-----BEGIN ([A-Z0-9 ]+)----- .*/\1/p')"
  if [ -z "$label" ]; then printf '%s\n' "$1"; return; fi
  body="$(printf '%s' "$value" | sed -E "s/^ *-----BEGIN $label----- *//; s/ *-----END $label----- *\$//" | tr -d '[:space:]')"
  printf -- '-----BEGIN %s-----\n%s\n-----END %s-----\n' "$label" "$(printf '%s' "$body" | fold -w 64)" "$label"
}

apple_dev_field() {
  secrets-run read "$APPLE_DEV_ITEM/$1" || { echo "  secrets-run read $APPLE_DEV_ITEM/$1 failed (make secrets-seed)" >&2; return 1; }
}

TEAM="${TEAM:-$(apple_dev_field team-id)}"
KEY_ID="$(apple_dev_field asc-key-id)"
ISSUER="$(apple_dev_field asc-issuer-id)"
KEY_FILE="$(mktemp "${TMPDIR:-/tmp}/iris-asc-key.XXXXXX")"
chmod 600 "$KEY_FILE"
P8="$(apple_dev_field asc-key-p8)"
pem_normalize "$P8" >"$KEY_FILE"
unset P8

# --- build ---------------------------------------------------------------------------------------------------------------

# Hardened Runtime and a secure timestamp are what notarization asks for; they cost nothing on a development build.
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO keeps Xcode from adding get-task-allow, which notarization refuses.
SIGN=(DEVELOPMENT_TEAM="$TEAM" CURRENT_PROJECT_VERSION="$BUILD" ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
AUTH=()
case "$IDENTITY" in
  development)
    # Xcode creates or fetches the team's Apple Development certificate through the ASC Team key.
    SIGN+=(CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development")
    AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY_FILE" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER")
    ;;
  developer-id)
    if ! security find-identity -v -p codesigning | grep -q "Developer ID Application.*($TEAM)"; then
      echo "  no 'Developer ID Application' identity of the paid team in the login keychain: the Account Holder creates the certificate" >&2
      echo "  (docs/research/2026-11-04-apple-paid-team.md); import the .p12 with its private key, then re-run" >&2
      exit 1
    fi
    SIGN+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application")
    ;;
esac

echo "  mac-release: identity=$IDENTITY publish=$PUBLISH build=$BUILD team=<resolved>"
rm -rf "$WORK"
mkdir -p "$UPLOAD"
(cd "$APPLE_DIR" && xcodegen generate --spec project.yml >/dev/null)
xcodebuild archive -project "$APPLE_DIR/Iris.xcodeproj" -scheme IrisMac -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED" \
  ${AUTH[@]+"${AUTH[@]}"} "${SIGN[@]}"

APP="$ARCHIVE/Products/Applications/IrisMac.app"
[ -d "$APP" ] || { echo "  archive holds no IrisMac.app at $APP" >&2; exit 1; }

# --- the signature -------------------------------------------------------------------------------------------------------

check_signature() {
  local app="$1" info ents
  codesign --verify --deep --strict "$app"
  info="$(codesign -dvv "$app" 2>&1)"
  ents="$(codesign -d --entitlements - --xml "$app" 2>/dev/null)"
  grep -E 'Authority=|TeamIdentifier=|flags=|Timestamp=|Identifier=' <<<"$info"
  # Here-strings, not `printf | grep -q`: under pipefail a grep that exits early SIGPIPEs the printf.
  grep -q "TeamIdentifier=$TEAM" <<<"$info" || { echo "  signature is not the paid team's" >&2; return 1; }
  grep -Eq 'flags=0x[0-9a-f]+\(.*runtime' <<<"$info" || { echo "  Hardened Runtime is off" >&2; return 1; }
  grep -q '^Timestamp=' <<<"$info" || { echo "  no secure timestamp" >&2; return 1; }
  grep -q 'com.apple.security.device.audio-input' <<<"$ents" || { echo "  audio-input entitlement missing" >&2; return 1; }
  if grep -q 'com.apple.security.app-sandbox' <<<"$ents"; then echo "  the app is sandboxed" >&2; return 1; fi
  if grep -q 'com.apple.security.get-task-allow' <<<"$ents"; then echo "  get-task-allow is set (notarization refuses it)" >&2; return 1; fi
}
check_signature "$APP"
[ "${SIGNING_ONLY:-0}" != "1" ] || { echo "  SIGNING_ONLY: stopping after the signature check"; exit 0; }

# --- notarize (Developer ID only) ----------------------------------------------------------------------------------------

if [ "$IDENTITY" = "developer-id" ]; then
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/notary.zip"
  xcrun notarytool submit "$WORK/notary.zip" --key "$KEY_FILE" --key-id "$KEY_ID" --issuer "$ISSUER" --wait --timeout 30m
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

# --- archive, appcast ----------------------------------------------------------------------------------------------------

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
VERSION="$(plist CFBundleShortVersionString)"
[ "$(plist CFBundleVersion)" = "$BUILD" ] || { echo "  CFBundleVersion is not $BUILD" >&2; exit 1; }
TAG="mac-v$VERSION-$BUILD"
ZIP="IrisMac-$VERSION-$BUILD.zip"
# The stapled app is what gets zipped, and the zip is signed last (stapling changes bytes).
ditto -c -k --sequesterRsrc --keepParent "$APP" "$UPLOAD/$ZIP"

# The tools of the pinned Sparkle package (matches the framework in the app); a manual download is the fallback.
SPARKLE_BIN="${SPARKLE_BIN:-}"
if [ -z "$SPARKLE_BIN" ]; then
  for dir in "$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin" "$HOME"/.local/share/sparkle/*/bin; do
    [ -x "$dir/generate_appcast" ] && { SPARKLE_BIN="$dir"; break; }
  done
fi
[ -x "$SPARKLE_BIN/generate_appcast" ] || { echo "  Sparkle tools not found (set SPARKLE_BIN)" >&2; exit 1; }

"$SPARKLE_BIN/generate_appcast" --ed-key-file "$SPARKLE_KEY_FILE" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" "$UPLOAD"
APPCAST="$UPLOAD/appcast.xml"
SIG="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$APPCAST" | head -n 1)"
[ -n "$SIG" ] || { echo "  appcast has no sparkle:edSignature" >&2; exit 1; }
grep -q "sparkle:version>$BUILD<" "$APPCAST" || { echo "  appcast version is not $BUILD" >&2; exit 1; }
"$SPARKLE_BIN/sign_update" --verify --ed-key-file "$SPARKLE_KEY_FILE" "$UPLOAD/$ZIP" "$SIG"
echo "  appcast signature verifies against $ZIP"

# --- publish -------------------------------------------------------------------------------------------------------------

if [ -z "${GH_TOKEN:-}" ]; then
  GH_TOKEN="$(secrets-run read op://mini/github/token 2>/dev/null || true)"
  if [ -n "$GH_TOKEN" ]; then export GH_TOKEN; else unset GH_TOKEN; fi
fi
FLAGS=(--repo "$REPO" --target "$SHA" --title "Iris Mac $VERSION ($BUILD)" --notes "Iris for Mac $VERSION, build $BUILD, signed $IDENTITY.")
if [ "$PUBLISH" = "draft" ]; then FLAGS+=(--draft); fi
gh release create "$TAG" "$UPLOAD/$ZIP" "$APPCAST" "${FLAGS[@]}"
echo "  released $TAG ($PUBLISH): $ZIP + appcast.xml"
