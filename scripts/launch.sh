#!/bin/zsh
# iris-server launcher — the ProgramArguments of com.jkrumm.iris (mini, :7730). Never point launchd
# at a Homebrew binary directly (macOS BTM silently disallows it); this wrapper is the required
# indirection, and it fails closed if any base secret can't resolve.
#
# Runs from the DEDICATED deploy clone (~/.iris/app), never the dev checkout: agents edit that
# constantly and a dirty tree must never go live. See Makefile mini-setup and scripts/mini-deploy.sh.

set -u

# IRIS_FAKES swaps every downstream for in-memory fakes (make e2e only): production must never boot it.
if [[ -n "${IRIS_FAKES:-}" ]]; then
  print -u2 "iris: IRIS_FAKES is set in the environment — refusing to start production with fake downstreams. Unset it."
  exit 78
fi

DIR="${0:A:h:h}"  # scripts/launch.sh -> repo root
cd "$DIR/server" || { print -u2 "iris: cannot cd to $DIR/server"; exit 78; }

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
else
  print -u2 "iris: neither 'timeout' nor 'gtimeout' on PATH — brew install coreutils"
  exit 78
fi

SECRETS_RUN="$HOME/.local/bin/secrets-run"
TPL_BASE="$DIR/.env.local.tpl"
TPL_MINI="$DIR/.env.mini.tpl"

[[ -x "$SECRETS_RUN" ]] || { print -u2 "iris: $SECRETS_RUN missing"; exit 78; }
[[ -f "$TPL_BASE" ]]   || { print -u2 "iris: $TPL_BASE missing"; exit 78; }
[[ -f "$TPL_MINI" ]]   || { print -u2 "iris: $TPL_MINI missing"; exit 78; }

# Assert every ref resolves BEFORE handing off — an unresolved ${VAR} would otherwise reach the
# process as a literal string.
RENDERED=$("$TIMEOUT_BIN" 20 "$SECRETS_RUN" export --env-file="$TPL_BASE" --env-file="$TPL_MINI" 2>/dev/null | /usr/bin/grep -c '^export ')
WANT=$(/usr/bin/grep -hoE '^[A-Za-z_][A-Za-z0-9_]*=' "$TPL_BASE" "$TPL_MINI" | /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/tr -d ' ')
if [[ -z "$RENDERED" || "$RENDERED" -lt "$WANT" ]]; then
  print -u2 "iris: only ${RENDERED:-0}/$WANT refs resolved — refusing to start."
  print -u2 "  Seed the missing refs (add to dotfiles-private/headless.refs, then \`make secrets-seed\` on the MacBook) and retry."
  exit 78
fi

# OTel is an optional overlay: secrets-run fails closed on ANY unresolved ref in a file, so probe
# it alone and start without it rather than not at all (index.ts reports `otel` in /health degraded).
OTEL_ARGS=()
OTEL_TPL="$DIR/.env.mini.otel.tpl"
if [[ -f "$OTEL_TPL" ]] && "$TIMEOUT_BIN" 20 "$SECRETS_RUN" export --env-file="$OTEL_TPL" >/dev/null 2>&1; then
  OTEL_ARGS=("--env-file=$OTEL_TPL")
else
  print -u2 "iris: ERROR otel overlay ($OTEL_TPL) does not resolve — starting DEGRADED without trace export."
fi

# Templates can't expand $HOME.
export IRIS_DATA="$HOME/.iris/data"
# Registers the herdr destination and the herd; left unset when herdr is not running, so neither is half-registered.
[[ -S "$HOME/.config/herdr/herdr.sock" ]] && export HERDR_SOCKET="$HOME/.config/herdr/herdr.sock"
# The herdr-core world beside it: registers the same destination and the herd's hc half. HC_SOCKET is the core's socket, so the
# adapter never spawns `hc` (which would start a core under this job) while the launchd core is down.
HC_BIN_PATH="$HOME/.local/bin/hc"
if [[ -x "$HC_BIN_PATH" ]]; then
  export HC_BIN="$HC_BIN_PATH"
  export HC_SOCKET="$HOME/.local/state/herdr-core/default/default.sock"
fi
# Registers the journal destination; left unset when the checkout is missing, so the server still boots.
[[ -d "$HOME/SourceRoot/brain" ]] && export BRAIN_DIR="$HOME/SourceRoot/brain"

# The audio door's caller token: the `iris=<token>` line of the local caller-token file (0600, not 1Password).
# Whitespace and a CR from a CRLF edit are stripped before the empty check. Never echoed. A missing file or line starts degraded (`transcribe` and `speech` in /health), the reason goes to stderr.
DOOR_TOKENS="$HOME/.agent-workflows/data/door-tokens"
if [[ -r "$DOOR_TOKENS" ]]; then
  AUDIO_DOOR_TOKEN=$(/usr/bin/awk -F= '$1=="iris" { sub(/^[^=]*=/, ""); print; exit }' "$DOOR_TOKENS" | /usr/bin/tr -d '[:space:]')
  if [[ -n "$AUDIO_DOOR_TOKEN" ]]; then
    export AUDIO_DOOR_TOKEN
  else
    unset AUDIO_DOOR_TOKEN
    print -u2 "iris: ERROR no iris= line in $DOOR_TOKENS — starting DEGRADED without STT/TTS."
  fi
else
  print -u2 "iris: ERROR $DOOR_TOKENS missing or unreadable — starting DEGRADED without STT/TTS."
fi

# HERMES_URL is composed here: the host is a secret, the port is not.
exec "$SECRETS_RUN" run --env-file="$TPL_BASE" --env-file="$TPL_MINI" "${OTEL_ARGS[@]}" -- \
  /bin/zsh -c 'export HERMES_URL="http://${HERMES_HOST}:${HERMES_PORT}"; exec bun run src/index.ts'
