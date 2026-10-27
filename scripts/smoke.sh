#!/bin/zsh
# End-to-end smoke: sends a real German recording through the production door and waits for
# `notified`. `make smoke` wraps this. Mini-only (needs secrets-run and the device-token cache).
#
#   IRIS_URL=https://iris.mini.<domain> AUDIO=<file> make smoke
#
# IRIS_URL (read by send-memo.ts) defaults to the loopback instance; AUDIO defaults to fixtures/audio/de-90s.m4a.
set -eu

DIR="${0:A:h:h}"
cd "$DIR"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

AUDIO="${AUDIO:-fixtures/audio/de-90s.m4a}"
[[ -f "$AUDIO" ]] || { print -u2 "smoke: audio file $AUDIO not found (set AUDIO=<file>)"; exit 2; }

TOKEN=$(secrets-run read op://mini/iris/device-tokens | /usr/bin/tr ',' '\n' | /usr/bin/awk -F= '$2 == "smoke" {print $1}')
[[ -n "$TOKEN" ]] || { print -u2 "smoke: no 'smoke' device in op://mini/iris/device-tokens"; exit 2; }

# `--mode hermes` is pinned on purpose: with journal and herdr registered, an `auto` memo could be
# routed into the real brain (a commit and a push) or typed into a live agent tab.
IRIS_TOKEN="$TOKEN" exec bun scripts/send-memo.ts "$AUDIO" --mode hermes --wait "${SMOKE_WAIT:-600}"
