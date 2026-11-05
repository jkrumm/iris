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
#   mac         MAC_RELEASE=1  `make mac-release`           ~/.iris/mac-release-sha   (only when the Makefile has the target)
# `~/.iris/release.env` is untracked and holds only those switches; absent or a switch not `1` = hook off (logged as skipped, once per tick).
# A hook runs when apple/** changed since its marker's SHA, or the marker is older than 7 days (TestFlight builds expire after 90 days).
# The marker is written only after the make target succeeded; a failure writes `<hook>-failed` and holds the hook off for an hour.
# Runs from the app clone, but every release builds in its own worktree (~/.iris/release-src/<hook>) at the exact SHA, so the poller's
# `git reset --hard` never moves sources under a running archive.
set -u

RELEASE_HOME="${RELEASE_HOME:-$HOME/.iris}"
APP_DIR="${APP_DIR:-$RELEASE_HOME/app}"
RELEASE_ENV="$RELEASE_HOME/release.env"
APPLE_LOCK="/tmp/iris-apple.lock"
WEEK_SECS=604800
FAILED_HOLD_SECS=3600
# lockf waits up to 30 min for the Apple lock (other workers share it); the build itself gets 40 min; jobrun's deadline covers both.
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
    mac:target) print "mac-release" ;;
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
  age=$(file_age_secs "$marker") || return
  if (( age > WEEK_SECS )); then
    print "marker is $(( age / 86400 )) days old (weekly rebuild)"
  fi
}

start_detached() { # <hook> <sha>
  local hook="$1" sha="$2" logfile="$HOME/Library/Logs/iris-release-$1.log"
  # A real session of its own (perl's setsid): the poller's jobrun kills its process group on a deadline. Output goes to the log file so
  # the poller's pipes close at once.
  perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec: $!"' -- \
    jobrun "com.jkrumm.iris-release-$hook" --owner iris --timeout "$JOB_DEADLINE_SECS" --lock "iris-release-$hook" -- \
    "$APP_DIR/scripts/release-hooks.sh" --run "$hook" "$sha" </dev/null >>"$logfile" 2>&1 &
}

decide() { # <sha>
  local sha="$1" hook sw reason failed_age target
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
    if [[ "${DRY_RUN:-}" == 1 ]]; then
      log "$hook DRY_RUN would start: make $target at ${sha[1,12]} ($reason); lockf $APPLE_LOCK, nice -n 10, detached jobrun com.jkrumm.iris-release-$hook"
      continue
    fi
    log "$hook starting detached: make $target at ${sha[1,12]} ($reason); output in ~/Library/Logs/iris-release-$hook.log"
    start_detached "$hook" "$sha"
  done
}

# The detached job (under jobrun, which holds iris-release-<hook>): a worktree at the SHA, the Apple lock, the make target, the marker.
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
  log "$hook: make $target (Apple lock, nice 10)"
  # shellcheck disable=SC2086  # $target is "testflight UPLOAD=1": two words on purpose
  (cd "$tree" && lockf -t "$LOCK_WAIT_SECS" "$APPLE_LOCK" nice -n 10 timeout "$BUILD_SECS" make ${=target})
  rc=$?
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
  local sha="${1:?usage: release-hooks.sh <sha> | --run <hook> <sha>}"
  decide "$sha"
}

main "$@"
