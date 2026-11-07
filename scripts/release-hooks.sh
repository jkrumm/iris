#!/bin/zsh
# iris/scripts/release-hooks.sh — the poller's release hooks (Wave 22). `mini-deploy.sh` runs `release-hooks.sh <sha>` on every tick whose
# master SHA is deployed (CI-green gated there); this starts at most one detached release per hook, never inline: the poller's own jobrun
# deadline is 1800 s and it must stay fast.
#
#   release-hooks.sh <sha>                    decide per hook, start detached jobs (DRY_RUN=1: print what would start, change nothing)
#   release-hooks.sh --run <hook> <sha>       the detached job itself: release tree at <sha>, Apple lock, make target, marker on success
#
# Hooks (name, switch in ~/.iris/release.env, make target, marker):
#   testflight  TESTFLIGHT=1   `make testflight UPLOAD=1`   ~/.iris/testflight-sha
#   mac         MAC_RELEASE=1  `make mac-release IDENTITY=developer-id`  ~/.iris/mac-release-sha   (only when the Makefile has the target)
# `~/.iris/release.env` is untracked and holds only those switches; absent or a switch not `1` = hook off (logged as skipped, once per tick).
# A hook is DUE when apple/** changed since its marker's SHA, or (testflight only) the marker is older than 7 days (TestFlight builds expire after 90 days).
# A due hook starts, at any hour, only when the automatic-release gate is open: the last release (the marker's mtime) is at least 12 h old, the Apple lock
# is free, and a factory test slot is free (so a release never runs next to another release or a lead's check). So a day of apple/** commits yields at
# most one automatic release per hook, and no commit starts one by itself. `make testflight` / `make mac-release` by hand never come through here.
# Overrides (tests): RELEASE_MIN_INTERVAL_SECS, APPLE_LOCK, FACTORY_BIN.
# Each job caps xcodebuild at SWIFT_JOBS (default 2, the Makefile's and apple-proof's number) and samples its process tree's resident memory; the peak
# lands in the job state as `peak_rss_mb` (jobrun rewrites its state file when the command ends, so the wrapper merges the number in afterwards).
# The marker is written only after the make target succeeded; a failure writes `<hook>-failed` and holds the hook off for an hour.
# Runs from the app clone, but every release builds in its own worktree (~/.iris/release-src/<hook>) at the exact SHA, so the poller's
# `git reset --hard` never moves sources under a running archive.
set -u

RELEASE_HOME="${RELEASE_HOME:-$HOME/.iris}"
APP_DIR="${APP_DIR:-$RELEASE_HOME/app}"
RELEASE_ENV="$RELEASE_HOME/release.env"
WEEK_SECS=604800
FAILED_HOLD_SECS=3600
MIN_INTERVAL_SECS="${RELEASE_MIN_INTERVAL_SECS:-43200}"
FACTORY_BIN="${FACTORY_BIN:-factory}"
APPLE_LOCK="${APPLE_LOCK:-/tmp/iris-apple.lock}"
JOBS_CAP="${SWIFT_JOBS:-2}"
SAMPLE_SECS=5
JOBS_STATE_DIR="${JOBS_STATE_DIR:-$HOME/.local/state/jobs}"
# scripts/apple-slot waits up to 30 min for the Apple lock and the factory test slot (other workers share them); the build itself gets 40 min; jobrun's deadline covers both.
LOCK_WAIT_SECS=1800
BUILD_SECS=2400
JOB_DEADLINE_SECS=4800

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

log() {
  print "[$(date '+%Y-%m-%dT%H:%M:%S%z')] release: $*"
}

# `NAME=1` in release.env; nothing else is read from it (never sourced).
switch_on() {
  [[ -f "$RELEASE_ENV" ]] && grep -qE "^$1=[\"']?1[\"']?[[:space:]]*\$" "$RELEASE_ENV"
}

hook_field() { # <hook> <field>
  case "$1:$2" in
    testflight:switch) print TESTFLIGHT ;;
    testflight:target) print "testflight UPLOAD=1" ;;
    testflight:marker) print "$RELEASE_HOME/testflight-sha" ;;
    mac:switch) print MAC_RELEASE ;;
    mac:target) print "mac-release IDENTITY=developer-id" ;;
    mac:marker) print "$RELEASE_HOME/mac-release-sha" ;;
  esac
}

file_age_secs() {
  local m
  m=$(stat -f %m "$1" 2>/dev/null) || return 1
  print $(( $(date +%s) - m ))
}

# Why the hook should run now: prints a reason, or nothing.
due_reason() { # <hook> <sha>
  local hook="$1" sha="$2" marker last age
  marker=$(hook_field "$hook" marker)
  last=$(cat "$marker" 2>/dev/null || print '')
  if [[ -z "$last" ]] || ! git -C "$APP_DIR" cat-file -e "${last}^{commit}" 2>/dev/null; then
    print "no usable marker: first release"
    return
  fi
  if [[ "$last" != "$sha" ]] && [[ -n "$(git -C "$APP_DIR" diff --name-only "$last" "$sha" -- apple 2>/dev/null)" ]]; then
    print "apple/** changed since ${last[1,12]}"
    return
  fi
  # The weekly rebuild is for TestFlight's 90-day expiry. A Mac release has none, and its tag (build = commit count) would already exist.
  [[ "$hook" == mac ]] && return
  age=$(file_age_secs "$marker") || return
  if (( age > WEEK_SECS )); then
    print "marker is $(( age / 86400 )) days old (weekly rebuild)"
  fi
}

# The automatic-release gate: prints why it is closed, or nothing when open.
gate_closed_reason() { # <hook>
  local marker age
  marker=$(hook_field "$1" marker)
  if age=$(file_age_secs "$marker") && (( age < MIN_INTERVAL_SECS )); then
    print "last release $(( age / 60 )) min ago (minimum $(( MIN_INTERVAL_SECS / 3600 )) h between automatic releases)"
    return
  fi
  if command -v lockf >/dev/null 2>&1 && ! lockf -t 0 "$APPLE_LOCK" true 2>/dev/null; then
    print "the Apple lock is held"
    return
  fi
  if test_slot_busy; then
    print "the factory test slots are busy"
  fi
}

# True when no factory test slot is free right now: a lease on one for no wait (exit 75 = none within the wait), given back at once.
# No `factory` (or a server outage, which `slot run` answers by running the command) counts as free.
test_slot_busy() {
  command -v "$FACTORY_BIN" >/dev/null 2>&1 || return 1
  FACTORY_SLOT_WAIT_MS=1 "$FACTORY_BIN" slot run --name iris-release-gate -- true >/dev/null 2>&1
  (( $? == 75 ))
}

start_detached() { # <hook> <sha>
  local hook="$1" sha="$2" logfile="$HOME/Library/Logs/iris-release-$1.log"
  # A real session of its own (perl's setsid): the poller's jobrun kills its process group on a deadline. Output goes to the log file so
  # the poller's pipes close at once.
  perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec: $!"' -- \
    zsh -c '
      began=$(date +%s)
      jobrun "com.jkrumm.iris-release-$1" --owner iris --timeout "$2" --lock "iris-release-$1" -- "$3/scripts/release-hooks.sh" --run "$1" "$4"
      rc=$?
      "$3/scripts/release-hooks.sh" --record-peak "$1" "$began"
      exit $rc
    ' release-hooks "$hook" "$JOB_DEADLINE_SECS" "$APP_DIR" "$sha" </dev/null >>"$logfile" 2>&1 &
}

decide() { # <sha>
  local sha="$1" hook sw reason failed_age target gated
  for hook in testflight mac; do
    sw=$(hook_field "$hook" switch)
    if ! switch_on "$sw"; then
      log "$hook skipped: $sw=1 not set in $RELEASE_ENV"
      continue
    fi
    target=$(hook_field "$hook" target)
    if [[ "$hook" == mac ]] && ! make -C "$APP_DIR" -n mac-release >/dev/null 2>&1; then
      log "$hook skipped: the Makefile has no mac-release target yet"
      continue
    fi
    reason=$(due_reason "$hook" "$sha")
    [[ -n "$reason" ]] || continue
    if failed_age=$(file_age_secs "$RELEASE_HOME/$hook-failed") && (( failed_age < FAILED_HOLD_SECS )); then
      log "$hook held off: it failed $(( failed_age / 60 )) min ago (retries after $(( FAILED_HOLD_SECS / 60 )) min)"
      continue
    fi
    if gated=$(gate_closed_reason "$hook") && [[ -n "$gated" ]]; then
      log "$hook due ($reason) but waiting: $gated"
      continue
    fi
    if [[ "${DRY_RUN:-}" == 1 ]]; then
      log "$hook DRY_RUN would start: make $target at ${sha[1,12]} ($reason); scripts/apple-slot, nice -n 10, detached jobrun com.jkrumm.iris-release-$hook"
      continue
    fi
    log "$hook starting detached: make $target at ${sha[1,12]} ($reason); output in ~/Library/Logs/iris-release-$hook.log"
    start_detached "$hook" "$sha"
  done
}

# Peak resident memory (KB, summed over the process tree below <root pid>) sampled every SAMPLE_SECS into <file>. RSS counts shared pages once per process,
# so this is an upper bound of the build's footprint, which is the safe direction for a budget.
sample_peak() { # <root pid> <file>
  local peak=0 now
  while true; do
    now=$(ps -axo pid=,ppid=,rss= | awk -v root="$1" '{ rss[$1]=$3; par[$1]=$2 } END { for (p in par) { q=p; while (q != "" && q != 0 && q != root) q=par[q]; if (q == root) s+=rss[p] } print s+0 }')
    (( now > peak )) && peak=$now && print -r -- "$peak" > "$2"
    sleep "$SAMPLE_SECS"
  done
}

# After jobrun ended (it rewrites the state file from scratch): add the peak to this run's state, only when jobrun really ran in this wrapper (a lock-held skip
# leaves the old state, and the running job's peak file alone).
record_peak() { # <hook> <wrapper start epoch>
  local hook="$1" began="$2" file state tmp kb
  file="$RELEASE_HOME/peak-$hook.kb"
  state="$JOBS_STATE_DIR/com.jkrumm.iris-release-$hook.json"
  [[ -f "$file" && -f "$state" ]] || return 0
  kb=$(cat "$file")
  tmp="$state.peak.$$"
  jq -e --argjson kb "${kb:-0}" --argjson began "$began" \
    'select((.started | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $began) | .peak_rss_mb = (($kb / 1024) | floor) | .peak_rss_run_id = .run_id' \
    "$state" > "$tmp" && mv -f "$tmp" "$state" && rm -f "$file" || rm -f "$tmp"
}

# The detached job (under jobrun, which holds iris-release-<hook>): a worktree at the SHA, the Apple slot, the make target, the marker.
run_hook() { # <hook> <sha>
  local hook="$1" sha="$2" marker tree target rc
  marker=$(hook_field "$hook" marker)
  target=$(hook_field "$hook" target)
  tree="$RELEASE_HOME/release-src/$hook"
  log "$hook: release tree $tree at ${sha[1,12]}"
  mkdir -p "${tree:h}"
  if [[ -d "$tree" ]]; then
    git -C "$tree" checkout --quiet --detach "$sha" || { log "$hook: checkout failed"; return 1; }
  else
    git -C "$APP_DIR" worktree prune
    git -C "$APP_DIR" worktree add --quiet --detach "$tree" "$sha" || { log "$hook: worktree add failed"; return 1; }
  fi
  log "$hook: make $target (apple-slot, nice 10, xcodebuild -jobs $JOBS_CAP)"
  rm -f "$RELEASE_HOME/peak-$hook.kb"
  sample_peak $$ "$RELEASE_HOME/peak-$hook.kb" &
  local sampler=$!
  # shellcheck disable=SC2086  # $target is "testflight UPLOAD=1": two words on purpose
  (cd "$tree" && SWIFT_JOBS="$JOBS_CAP" APPLE_LOCK_WAIT="$LOCK_WAIT_SECS" scripts/apple-slot nice -n 10 timeout "$BUILD_SECS" make ${=target})
  rc=$?
  kill "$sampler" 2>/dev/null
  log "$hook: peak memory $(( $(cat "$RELEASE_HOME/peak-$hook.kb" 2>/dev/null || print 0) / 1024 )) MB (process-tree RSS)"
  if (( rc != 0 )); then
    log "$hook: FAILED rc=$rc — held off for $(( FAILED_HOLD_SECS / 60 )) min"
    print -r -- "$sha" > "$RELEASE_HOME/$hook-failed"
    return $rc
  fi
  rm -f "$RELEASE_HOME/$hook-failed"
  print -r -- "$sha" > "$marker.tmp.$$" && mv -f "$marker.tmp.$$" "$marker"
  log "$hook: released ${sha[1,12]}, marker written"
}

main() {
  if [[ "${1:-}" == "--run" ]]; then
    run_hook "${2:?hook}" "${3:?sha}"
    return
  fi
  if [[ "${1:-}" == "--record-peak" ]]; then
    record_peak "${2:?hook}" "${3:?wrapper start epoch}"
    return
  fi
  local sha="${1:?usage: release-hooks.sh <sha> | --run <hook> <sha>}"
  decide "$sha"
}

main "$@"
