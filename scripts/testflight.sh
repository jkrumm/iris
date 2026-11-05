#!/usr/bin/env bash
# TestFlight build of Iris from the mini: archive Release, export a signed .ipa (UPLOAD=0, default) or export-and-upload (UPLOAD=1).
#   UPLOAD=0|1   0 (default until the App Store Connect app record exists): destination `export`, the .ipa lands in .artifacts/testflight/export
#                1: destination `upload`, xcodebuild -exportArchive sends the build to App Store Connect
# Team id and the App Store Connect Team key come from op://mini/apple-developer via secrets-run (scripts/apple-signing-key.sh); the key is a
# 0600 temp file deleted on every exit, nothing secret reaches argv or a log. CFBundleVersion = "<commit count>.<UTC epoch hours>", never committed:
# App Store Connect rejects a repeated build number, so a same-sha weekly rebuild must still raise it (the second component).
# `make testflight` runs this through scripts/apple-slot like every xcodebuild job (the poller's release hook wraps its make call the same way).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/apple-signing-key.sh

UPLOAD="${UPLOAD:-0}"
case "$UPLOAD" in 0 | 1) ;; *) echo "  UPLOAD must be 0 or 1, not '$UPLOAD'" >&2; exit 1 ;; esac
APPLE_DIR="${APPLE_DIR:-apple}"
OUT="${ARTIFACTS:-.artifacts}/testflight"
ARCHIVE="$OUT/Iris.xcarchive"
EXPORT_DIR="$OUT/export"
LOG="$OUT/testflight.log"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/iris-testflight.XXXXXX")"
trap 'rm -rf "$TMP_DIR"; rm -f "${KEY_FILE:-}"' EXIT

# Strictly increasing per upload: a new commit raises the first component, a rebuild of the same sha the second (1-3 dot-separated integers).
build="$(git rev-list --count HEAD).$(( $(date -u +%s) / 3600 ))"
sha="$(git rev-parse --short HEAD)"
team="${TEAM:-$(apple_dev_field team-id)}"
paid_signing_setup
rm -rf "$OUT"
mkdir -p "$OUT"
echo "  testflight: build=$build sha=$sha team=<resolved> upload=$UPLOAD"

# Runs one xcodebuild step with its whole output in $LOG; a failure prints the tail and the hints below.
step() {
  local name="$1"; shift
  echo "  $name ..."
  if ! "$@" >>"$LOG" 2>&1; then
    echo "  $name FAILED (full log: $LOG); last lines:" >&2
    tail -n 40 "$LOG" >&2
    hint
    return 1
  fi
}

hint() {
  if grep -qiE "no signing certificate|distribution certificate|Cloud signing permission|requires a development team" "$LOG"; then
    cat >&2 <<'MSG'
  Signing needs an Apple Distribution identity and cloud signing did not provide one. Either:
    - the Account Holder gives the Team key the Admin role (App Store Connect > Users and Access > Integrations > Team Keys; cloud-managed
      certificates need Admin or Account Holder rights), or
    - an Apple Distribution certificate with its private key is added to the mini's login keychain (Account Holder: Certificates, Identifiers & Profiles).
  This script never creates certificates.
MSG
  fi
  if grep -qiE "application-groups|App Group" "$LOG"; then
    echo "  The App Group group.com.jkrumm.iris is missing from the portal: the Account Holder creates it (Identifiers > App Groups) and adds it to the three App IDs." >&2
  fi
  if grep -qiE "No profiles for|Cannot find|app record|appstoreconnect.*not found|App Store Connect app" "$LOG" && [ "$UPLOAD" = 1 ]; then
    echo "  If the upload names a missing app: the App Store Connect app record for com.jkrumm.iris is created by the Account Holder first." >&2
  fi
}

(cd "$APPLE_DIR" && xcodegen generate --quiet) >>"$LOG" 2>&1 || { echo "  xcodegen failed (see $LOG)" >&2; exit 1; }

step "archive (Release, generic/platform=iOS)" \
  xcodebuild archive -project "$APPLE_DIR/Iris.xcodeproj" -scheme Iris -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -derivedDataPath "$APPLE_DIR/.dd.noindex" \
  "${SIGNING_ARGS[@]}" DEVELOPMENT_TEAM="$team" CURRENT_PROJECT_VERSION="$build" IRIS_BUILD_SHA="$sha"

# The three Info.plists carry a literal CFBundleVersion, so the build setting above does not reach them. Set it in the archive: the export
# re-signs everything. (The proper fix is `$(CURRENT_PROJECT_VERSION)` in the plists; then this loop finds nothing to change.)
patched=0
while IFS= read -r plist; do
  current="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)"
  if [ -n "$current" ] && [ "$current" != "$build" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist"
    patched=$((patched + 1))
  fi
done < <(find "$ARCHIVE/Products/Applications" -name Info.plist -path '*.app/Info.plist' -o -name Info.plist -path '*.appex/Info.plist')
echo "  CFBundleVersion set to $build in $patched plist(s) of the archive"

# The export options: the tracked template plus the team id and the destination, in a temp copy.
options="$TMP_DIR/ExportOptions.plist"
cp "$APPLE_DIR/ExportOptions.plist" "$options"
/usr/libexec/PlistBuddy -c "Add :teamID string $team" "$options"
/usr/libexec/PlistBuddy -c "Add :destination string $([ "$UPLOAD" = 1 ] && echo upload || echo export)" "$options"

step "export (destination $([ "$UPLOAD" = 1 ] && echo upload || echo export))" \
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" -exportOptionsPlist "$options" "${SIGNING_ARGS[@]}"

if [ "$UPLOAD" = 1 ]; then
  echo "  uploaded build $build ($sha) to App Store Connect; processing takes a few minutes, then the internal group's automatic distribution takes over"
  exit 0
fi

ipa="$(find "$EXPORT_DIR" -name '*.ipa' | head -n 1)"
[ -n "$ipa" ] || { echo "  export produced no .ipa in $EXPORT_DIR" >&2; exit 1; }
unzip -q "$ipa" -d "$TMP_DIR/ipa"
app="$(find "$TMP_DIR/ipa/Payload" -maxdepth 1 -name '*.app' | head -n 1)"
echo "  exported $ipa"
echo "  signature of $(basename "$app") (the team id, the Authority chain):"
codesign -dvv "$app" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Signed Time)=' | sed 's/^/    /'
codesign -d --entitlements :- "$app" >"$TMP_DIR/entitlements.plist" 2>/dev/null || true
echo "  aps-environment: $(/usr/libexec/PlistBuddy -c 'Print :aps-environment' "$TMP_DIR/entitlements.plist" 2>/dev/null || echo '<none>')"
