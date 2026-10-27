# Local/base secrets template — consumed via `secrets-run` (drop-in `op run` shim; see server's
# `dev` script and scripts/launch.sh). Substitutes only whole-value op:// refs.
# Public repo: hostnames live in 1Password, never here. New refs go into
# dotfiles-private/headless.refs, then `make secrets-seed` on the MacBook.

PORT=7730

# `token=device,token=device`; the `smoke` entry is what `make smoke` uses.
IRIS_DEVICE_TOKENS=op://mini/iris/device-tokens

# audio-gateway (STT) base URL
AUDIO_GATEWAY_URL=op://mini/iris/audio-gateway-url

# agent-gateway: loopback, no auth
AGW_URL=http://127.0.0.1:7705

# Hermes API server. scripts/launch.sh composes HERMES_URL from host + port (templates
# substitute whole values only).
HERMES_HOST=op://hermes/gateway/host
HERMES_PORT=8642
HERMES_TOKEN=op://hermes/gateway/api-server-key
