#!/bin/zsh
# iris/scripts/mini-deploy.sh — the mini's "push to master deploys": com.jkrumm.iris-deploy polls
# this every 2 minutes (launchd/com.jkrumm.iris-deploy.plist.template). Same shape as
# research-gateway's: CI-green gate, idle gate, restart only for runtime paths, deployed-sha marker
# written only after the new process proved healthy.
#
# Everything lives inside `main`, invoked on the LAST line: this file is tracked in the repo the
# `git reset --hard` pulls from, and zsh has parsed the whole function body before the reset
# rewrites the file on disk. Do not move logic outside `main`, and do not `source` this file.
#
# Locking and the deadline live outside, in `jobrun ... --lock iris-deploy --timeout 1800`; a held
# lock skips the tick. `make deploy` goes through the same wrapper, so they never overlap.

set -u

APP_DIR="$HOME/.iris/app"
DATA_DIR="$HOME/.iris/data"
DEPLOYED_SHA_FILE="$HOME/.iris/deployed-sha"
HEALTH_URL="http://127.0.0.1:7730/health"
LABEL="com.jkrumm.iris"

# The name of check.yml's job: GitHub creates a check run under this exact name.
CI_CHECK_NAME="check"
CI_REPO="jkrumm/iris"

EMPTY_TREE_SHA="4b825dc642cb6eb9a060e54bf8d69288fbee4904"

# The server drains a running step for up to 30 s on SIGTERM; wait comfortably past that.
HEALTH_POLL_SECS=120

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

log() {
  print "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*"
}

# The mini heartbeat pages on every `runs` bump of a KeepAlive job; one epoch line written right
# before the restart marks exactly one bump as deliberate. Best-effort.
mark_deliberate_restart() {
  local dir="$HOME/.local/state/devhost/deliberate-restart"
  mkdir -p "$dir" 2>/dev/null && date +%s >> "$dir/$1" 2>/dev/null || true
}

# Atomic: a reader must never observe a partially written marker.
write_deployed_sha() {
  local sha="$1" tmp
  tmp="$DEPLOYED_SHA_FILE.tmp.$$"
  print -r -- "$sha" > "$tmp" && mv -f "$tmp" "$DEPLOYED_SHA_FILE"
}

service_pid() {
  launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | /usr/bin/awk '/^[[:space:]]*pid = /{print $3; exit}'
}

# Prints success|pending|failure|unreachable for $1 (a full SHA). Bounded by curl's --max-time and
# never throws. The token is the mini's push credential, read via secrets-run (never `op`).
ci_gate_status() {
  local sha="$1" token resp
  token=$(secrets-run read op://mini/github/token 2>/dev/null)
  if [[ -z "$token" ]]; then
    print "unreachable"
    return 0
  fi

  resp=$(curl -fsS --max-time 10 \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$CI_REPO/commits/$sha/check-runs" 2>/dev/null)
  if [[ -z "$resp" ]]; then
    print "unreachable"
    return 0
  fi

  print -r -- "$resp" | jq -r --arg name "$CI_CHECK_NAME" '
    [.check_runs[]? | select(.name == $name)] as $runs
    | if ($runs | length) == 0 then "unreachable"
      elif ($runs | map(.status) | any(. != "completed")) then "pending"
      elif ($runs | map(.conclusion) | all(. == "success")) then "success"
      else "failure"
      end
  ' 2>/dev/null || print "unreachable"
}

main() {
  mkdir -p "$DATA_DIR"

  if [[ ! -d "$APP_DIR/.git" ]]; then
    log "ERROR: $APP_DIR is not a git clone yet — run 'make mini-setup' first"
    return 1
  fi

  if ! git -C "$APP_DIR" fetch --quiet origin master; then
    log "ERROR: git fetch origin master failed — will retry next tick"
    return 1
  fi

  # The deployed-sha marker (not HEAD) is the source of truth: it is written only after the restart
  # came back healthy, whereas `git reset --hard` moves HEAD before that is known. A missing file
  # reads as "" and never equals a real sha.
  local origin_head deployed_sha
  origin_head=$(git -C "$APP_DIR" rev-parse origin/master)
  deployed_sha=$(cat "$DEPLOYED_SHA_FILE" 2>/dev/null || print '')
  if [[ -n "$deployed_sha" && "$deployed_sha" == "$origin_head" ]]; then
    return 0
  fi

  local ci_status
  ci_status=$(ci_gate_status "$origin_head")
  case "$ci_status" in
    success) ;;
    pending)
      log "waiting for CI on ${origin_head[1,12]} — skipping this tick"
      return 0
      ;;
    failure)
      log "ERROR: CI failed on ${origin_head[1,12]} — refusing to deploy, will retry next tick"
      return 0
      ;;
    *)
      log "ERROR: GitHub check-runs API unreachable for ${origin_head[1,12]} — refusing to deploy unchecked"
      return 0
      ;;
  esac

  # Idle gate: a restart abandons the running step's HTTP calls (the memo resumes at the same step
  # on boot, but `act` is at-least-once), so defer while any memo is mid-step. A down service
  # deploys anyway.
  local health inflight=0
  if health=$(curl -fsS --max-time 5 "$HEALTH_URL" 2>/dev/null); then
    inflight=$(print -r -- "$health" | jq -r '.inflight // 0' 2>/dev/null || print 0)
    if (( inflight > 0 )); then
      log "deferred: $inflight memo(s) in flight — will retry next tick"
      return 0
    fi
  else
    log "GET $HEALTH_URL unreachable — deploying anyway"
  fi

  # Diff from deployed-sha so a retry after a failed install still sees the changed paths. No
  # trustworthy base (first deploy, force-push) diffs against the empty tree: everything changed.
  local base_ref="$EMPTY_TREE_SHA"
  if [[ -n "$deployed_sha" ]] \
    && git -C "$APP_DIR" cat-file -e "${deployed_sha}^{commit}" 2>/dev/null \
    && git -C "$APP_DIR" merge-base --is-ancestor "$deployed_sha" "$origin_head" 2>/dev/null; then
    base_ref="$deployed_sha"
  fi

  local changed
  changed=$(git -C "$APP_DIR" diff --name-only "$base_ref" "$origin_head")
  local -a changed_arr
  changed_arr=("${(@f)changed}")
  local from_label="none"
  [[ -n "$deployed_sha" ]] && from_label="${deployed_sha[1,12]}"
  log "deploying $from_label -> ${origin_head[1,12]} (${#changed_arr} changed path(s): ${(j:, :)changed_arr[1,20]}${${changed_arr[21]:+, …}:-})"

  if ! git -C "$APP_DIR" reset --hard origin/master >/dev/null; then
    log "ERROR: git reset --hard origin/master failed"
    return 1
  fi

  local deps_changed=0 restart_needed=0 launchd_changed=0 f
  for f in "${changed_arr[@]}"; do
    case "$f" in
      server/package.json|server/bun.lock) deps_changed=1; restart_needed=1 ;;
      *.md|docs/*) ;;  # docs-only changes never restart anything
      *.test.ts|.github/*|Makefile|scripts/send-memo.ts|scripts/smoke.sh) ;;
      launchd/*) launchd_changed=1 ;;
      *) restart_needed=1 ;;
    esac
  done

  if [[ "$deps_changed" -eq 1 ]]; then
    log "server/package.json or bun.lock changed — bun install --frozen-lockfile --production"
    if ! (cd "$APP_DIR/server" && bun install --frozen-lockfile --production); then
      log "ERROR: bun install failed — leaving the service on its current running build"
      return 1
    fi
  fi

  if [[ "$launchd_changed" -eq 1 ]]; then
    log "WARNING: launchd/ templates changed — this deploy does NOT re-render or reload plists. Run 'make launchd-install' by hand."
  fi

  if [[ "$restart_needed" -eq 0 ]]; then
    write_deployed_sha "$origin_head"
    log "deployed $(git -C "$APP_DIR" rev-parse --short HEAD) — no restart-worthy paths changed, service left running"
    return 0
  fi

  # `kickstart -k` returns before the old process is gone, so the first /health answers can still
  # come from it. Only a changed pid proves the new process is serving.
  local prev_pid
  prev_pid=$(service_pid)

  log "restarting $LABEL"
  mark_deliberate_restart "$LABEL"
  launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>&1 | while IFS= read -r l; do log "  $l"; done

  local i=0 ok=0 pid
  while (( i < HEALTH_POLL_SECS )); do
    pid=$(service_pid)
    if [[ -n "$pid" && "$pid" != "$prev_pid" ]] && curl -fsS --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 1; i=$((i + 1))
  done

  local sha
  sha=$(git -C "$APP_DIR" rev-parse --short HEAD)
  if [[ "$ok" -eq 1 ]]; then
    write_deployed_sha "$origin_head"
    log "deploy OK — $sha up and healthy after restart"
  else
    log "ERROR: deploy of $sha did NOT come back healthy within ${HEALTH_POLL_SECS}s — check ~/Library/Logs/iris.err"
    return 1
  fi
}

main
