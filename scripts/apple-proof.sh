#!/usr/bin/env bash
# apple-proof.sh — one verifier run that proves an Apple change on the mini: iOS in the pinned simulator, then the Mac app.
#
# Run it through `make proof-apple` (the Makefile wraps it in scripts/apple-slot --sim: one Apple job at a time, every simulator
# shut down when it ends). Starting from a clean state, it:
#   1. shuts every simulator down, erases the pinned one (refuses to start while an IrisMac is already running)
#   2. iOS: builds Iris, installs, launches with -IrisFakeCapture, writes the screenshot and the UI element tree
#   3. Mac: builds IrisMac, launches it with -IrisFakeData -IrisMacPanelWindow -IrisMacSnapshot <dir> (the app renders its own windows
#      to PNG and quits; the mini has no Screen Recording grant, so screencapture cannot see it)
#   4. shuts every simulator down and prints the artifacts, the simulator state and the load (start, peak, end)
#
# Output: .artifacts/proof/<time>/{ios/,mac/,mac-de/,proof.txt} (mac/ English, mac-de/ German). Exit 0 only when the iOS screenshot and every expected Mac PNG exist
# and no simulator is left booted. This proves "it builds, launches and looks right"; the test suites stay CI's.
# Env: SIM_NAME / SIM_OS (the Makefile's pinned simulator), IOS_ARGS (extra launch arguments for Iris), PROOF_MAC=0 / PROOF_IOS=0
# (skip a half), UI_SETTLE (seconds before the UI tree, default 8), MAC_TIMEOUT (seconds for the Mac snapshot run, default 240).
set -uo pipefail
cd "$(dirname "$0")/.."

SIM_NAME=${SIM_NAME:-iPhone 17}
SIM_OS=${SIM_OS:-27.0}
UI_SETTLE=${UI_SETTLE:-8}
MAC_TIMEOUT=${MAC_TIMEOUT:-240}
APP_BUNDLE=com.jkrumm.iris
DD=apple/.dd.noindex
# Capped like the Makefile's test runners: 2 build jobs (an uncapped cold build of both schemes peaked at a 1-minute load of 408 on 12 cores), low priority.
XCB=(nice -n 10 xcodebuild -project apple/Iris.xcodeproj -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO -jobs "${SWIFT_JOBS:-2}"
  IDEBuildOperationMaxNumberOfConcurrentCompileTasks="${SWIFT_JOBS:-2}" SWIFT_COMPILATION_MODE=incremental)
MAC_EXPECTED=(menu menu-ask window-all window-thread window-chat-mermaid window-running window-streaming window-filtered window-new window-composer window-sent
  window-answered settings-connection settings-recording settings-general onboarding recording recording-refused artifact-island artifact-island-dark
  artifact-cards artifact-cards-dark artifact-viewer artifact-viewer-dark)

out=.artifacts/proof/$(date +%Y%m%d-%H%M%S)
mkdir -p "$out/ios" "$out/mac" "$out/mac-de"
report="$out/proof.txt"
failures=0

say() { echo "$*" | tee -a "$report"; }
fail() { say "FAIL: $*"; failures=$((failures + 1)); }
load1() { sysctl -n vm.loadavg | awk '{print $2}'; }

# A sampler records "<phase> <1-minute load>" every 5 s. The load is host-wide: other jobs on the mini count too, so the report shows
# the start and end value next to the per-phase peak (a peak far above both is this run's).
loadlog=$(mktemp)
phasefile=$(mktemp)
phase() { echo "$1" >"$phasefile"; }
phase start
(while :; do echo "$(cat "$phasefile") $(load1)" >>"$loadlog"; sleep 5; done) &
sampler=$!
cleanup() {
  kill "$sampler" 2>/dev/null
  xcrun simctl shutdown all >/dev/null 2>&1 || true
  rm -f "$loadlog" "$phasefile"
}
trap cleanup EXIT
trap 'exit 143' TERM HUP INT

say "proof-apple $(date -u +%FT%TZ) sha=$(git rev-parse --short HEAD) load_start=$(load1)"

# --- 1. clean state
xcrun simctl shutdown all >/dev/null 2>&1 || true
if [[ "${PROOF_MAC:-1}" != 0 ]] && pgrep -x IrisMac >/dev/null; then
  echo "an IrisMac is already running; quit it first (the snapshot run would collide with it)" >&2
  exit 1
fi
udid=$(xcrun simctl list devices available -j | jq -r --arg rt "com.apple.CoreSimulator.SimRuntime.iOS-${SIM_OS//./-}" --arg n "$SIM_NAME" \
  '.devices[$rt] // [] | map(select(.name == $n)) | first | .udid // empty')

# The artifact island spike (WebView islands in the demo screen): light and dark screenshots, then the WebKit memory for 1, 5 and
# 10 islands. The screenshots count; the memory file is fail-soft (it says why when it could not measure).
mb_of() { # <pid>: "<MB> footprint|rss" (footprint where the system lets us read it, else resident size)
  local value
  value=$(footprint -p "$1" 2>/dev/null | awk '/Footprint:/ { v = $2; if ($3 == "KB") v /= 1024; else if ($3 == "GB") v *= 1024; printf "%.1f", v; exit }')
  # A simulator process reads 0 (no dirty-page accounting for it): that is not a measurement, fall back to the resident size.
  [[ -n "$value" && "$value" != "0.0" ]] && { echo "$value footprint"; return; }
  ps -o rss= -p "$1" 2>/dev/null | awk '{ printf "%.1f rss\n", $1 / 1024 }'
}
# The simulator's WebContent processes are host processes (the simulator runtime's WebKit): the ones that appear after the app
# launches, since the baseline, are the app's. No IrisMac runs here (checked above), other apps' WebContent stays in the baseline.
sim_webcontent_pids() { pgrep -f 'com.apple.WebKit.WebContent' | sort -u; }
# The sample reply's artifact cards and the viewer on the sample document (`-IrisArtifactSample cards|viewer`), light and dark.
artifact_screens() {
  local screen appearance
  for screen in cards viewer; do
    for appearance in light dark; do
      xcrun simctl terminate "$udid" "$APP_BUNDLE" >/dev/null 2>&1 || true
      xcrun simctl ui "$udid" appearance "$appearance" >/dev/null 2>&1 || true
      xcrun simctl launch "$udid" "$APP_BUNDLE" -IrisArtifactSample "$screen" -IrisFakeCapture -AppleLanguages "(en)" -AppleLocale en_US >>"$out/ios/artifact-launch.txt" 2>&1 || true
      sleep 16
      xcrun simctl io "$udid" screenshot "$out/ios/artifact-$screen-$appearance.png" >/dev/null 2>&1
    done
  done
  xcrun simctl ui "$udid" appearance light >/dev/null 2>&1 || true
  xcrun simctl terminate "$udid" "$APP_BUNDLE" >/dev/null 2>&1 || true
}
artifact_spike() {
  local spike=(-IrisArtifactSpike -IrisFakeCapture -AppleLanguages "(en)" -AppleLocale en_US)
  xcrun simctl terminate "$udid" "$APP_BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl ui "$udid" appearance light >/dev/null 2>&1 || true
  xcrun simctl launch "$udid" "$APP_BUNDLE" "${spike[@]}" >"$out/ios/artifact-launch.txt" 2>&1 || true
  sleep 16
  xcrun simctl io "$udid" screenshot "$out/ios/artifact-light.png" >/dev/null 2>&1
  xcrun simctl ui "$udid" appearance dark >/dev/null 2>&1 || true
  xcrun simctl terminate "$udid" "$APP_BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl launch "$udid" "$APP_BUNDLE" "${spike[@]}" >>"$out/ios/artifact-launch.txt" 2>&1 || true
  sleep 16
  xcrun simctl io "$udid" screenshot "$out/ios/artifact-dark.png" >/dev/null 2>&1
  xcrun simctl ui "$udid" appearance light >/dev/null 2>&1 || true
  xcrun simctl terminate "$udid" "$APP_BUNDLE" >/dev/null 2>&1 || true

  local memory="$out/ios/artifact-memory.txt"
  if ! command -v footprint >/dev/null 2>&1 && ! command -v ps >/dev/null 2>&1; then
    echo "not measured: neither footprint nor ps found" >"$memory"
    return
  fi
  local baseline n pid app_pid line pids count total app unit
  baseline=$(sim_webcontent_pids)
  echo "baseline webcontent_pids=$(echo "$baseline" | grep -c .)" >"$memory"
  for n in 1 5 10; do
    xcrun simctl terminate "$udid" "$APP_BUNDLE" >/dev/null 2>&1 || true
    sleep 1
    app_pid=$(xcrun simctl launch "$udid" "$APP_BUNDLE" -IrisArtifactSpike -IrisArtifactIslands "$n" -IrisFakeCapture -AppleLanguages "(en)" -AppleLocale en_US 2>&1 | awk -F': ' '/:/ { print $NF; exit }')
    sleep 16
    pids=$(comm -13 <(echo "$baseline") <(sim_webcontent_pids))
    count=0 total=0
    for pid in $pids; do
      line=$(mb_of "$pid")
      [[ -n "$line" ]] || continue
      count=$((count + 1))
      total=$(awk -v a="$total" -v b="${line%% *}" 'BEGIN { printf "%.1f", a + b }')
      unit=${line##* }
    done
    app=$(mb_of "${app_pid:-0}")
    if ((count == 0)); then
      echo "islands=$n not measured: no new WebContent process appeared on the host (pgrep -f com.apple.WebKit.WebContent)" >>"$memory"
    else
      echo "islands=$n webcontent_processes=$count webcontent_footprint_mb=$total webcontent_source=$unit app_footprint_mb=${app%% *}" >>"$memory"
    fi
  done
  xcrun simctl terminate "$udid" "$APP_BUNDLE" >/dev/null 2>&1 || true
}

# --- 2. iOS
if [[ "${PROOF_IOS:-1}" != 0 ]]; then
  if [[ -z "$udid" ]]; then
    fail "no simulator '$SIM_NAME' on iOS $SIM_OS (xcrun simctl list devices available)"
  else
    phase ios-boot
    xcrun simctl erase "$udid" >/dev/null 2>&1 || true
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1
    say "ios: simulator $SIM_NAME iOS $SIM_OS ($udid) booted from a clean state"
    phase ios-build
    if "${XCB[@]}" -scheme Iris -destination "platform=iOS Simulator,id=$udid" build >"$out/ios/build.log" 2>&1; then
      phase ios-run
      app="$DD/Build/Products/Debug-iphonesimulator/Iris.app"
      xcrun simctl install "$udid" "$app" && xcrun simctl launch "$udid" "$APP_BUNDLE" -IrisFakeCapture -AppleLanguages "(en)" -AppleLocale en_US ${IOS_ARGS:-} >"$out/ios/launch.txt" 2>&1
      sleep "$UI_SETTLE"
      xcrun simctl io "$udid" screenshot "$out/ios/launch.png" >/dev/null 2>&1
      # The first remote automation session on a freshly erased simulator can time out under load: one retry after a longer settle.
      scripts/mbm ui-automation snapshot-ui --simulator-id "$udid" >"$out/ios/ui-snapshot.txt" 2>&1 ||
        { sleep 20; scripts/mbm ui-automation snapshot-ui --simulator-id "$udid" >"$out/ios/ui-snapshot.txt" 2>&1; } ||
        say "ios: ui tree not read (see ios/ui-snapshot.txt), screenshot still counts"
      [[ -s "$out/ios/launch.png" ]] || fail "ios: no screenshot"
      phase ios-artifact
      artifact_spike || say "ios: artifact spike measurement failed (see ios/artifact-memory.txt)"
      artifact_screens
      for name in artifact-light artifact-dark artifact-cards-light artifact-cards-dark artifact-viewer-light artifact-viewer-dark; do
        [[ -s "$out/ios/$name.png" ]] || fail "ios: $name.png missing"
      done
    else
      fail "ios: build failed, tail of $out/ios/build.log:"
      tail -n 15 "$out/ios/build.log" | tee -a "$report"
    fi
    xcrun simctl shutdown all >/dev/null 2>&1 || true
  fi
fi

# --- 3. Mac
if [[ "${PROOF_MAC:-1}" != 0 ]]; then
  phase mac-build
  if "${XCB[@]}" -scheme IrisMac -destination 'platform=macOS' build >"$out/mac/build.log" 2>&1; then
    phase mac-run
    bin="$DD/Build/Products/Debug/IrisMac.app/Contents/MacOS/IrisMac"
    # One build, two launches: English into mac/, German into mac-de/ (window titles are localized; the run looks them up in the
    # language it runs in). The same names are expected from both.
    mac_snapshot() { # <directory> <language> <locale>
      local dir=$1 lang=$2 locale=$3
      mkdir -p "$out/$dir"
      # The flags order matters: -IrisMacSnapshot goes after -IrisMacPanelWindow (TDD §5).
      "$bin" -IrisFakeData -IrisMacPanelWindow -IrisMacSnapshot "$PWD/$out/$dir" -AppleLanguages "($lang)" -AppleLocale "$locale" >"$out/$dir/run.log" 2>&1 &
      local pid=$!
      local waited=0
      while kill -0 "$pid" 2>/dev/null && ((waited < MAC_TIMEOUT)); do
        sleep 2
        waited=$((waited + 2))
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        fail "mac ($lang): snapshot run still alive after ${MAC_TIMEOUT}s, killed"
      fi
      for name in "${MAC_EXPECTED[@]}"; do
        [[ -s "$out/$dir/$name.png" ]] || fail "mac ($lang): $name.png missing"
      done
    }
    mac_snapshot mac en en_US
    mac_snapshot mac-de de de_DE
  else
    fail "mac: build failed, tail of $out/mac/build.log:"
    tail -n 15 "$out/mac/build.log" | tee -a "$report"
  fi
fi

# --- 4. leave nothing behind, report
xcrun simctl shutdown all >/dev/null 2>&1 || true
booted=$(xcrun simctl list devices booted | grep -c Booted || true)
((booted == 0)) || fail "$booted simulator(s) still booted"
say "simulators booted: $booted"
say "load (host-wide 1-minute average, budget < 40): start $(awk 'NR == 1 {print $2}' "$loadlog"), end $(load1); peak per phase:"
awk '{ if (!($1 in p) || $2 > p[$1]) p[$1] = $2; if (!($1 in o)) { o[$1] = ++n; k[n] = $1 } } END { for (i = 1; i <= n; i++) printf "  %s %s\n", k[i], p[k[i]] }' "$loadlog" | tee -a "$report"
say "artifacts:"
find "$out" -name '*.png' -o -name '*.txt' | sort | sed 's/^/  /' | tee -a "$report"
if ((failures > 0)); then
  say "proof-apple: $failures failure(s)"
  exit 1
fi
say "proof-apple: ok -> $out"
