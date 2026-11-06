# Mini overlay — the LaunchAgent instance. Layered on .env.local.tpl:
#   secrets-run run --env-file=.env.local.tpl --env-file=.env.mini.tpl -- ...
# Last file wins per key. See scripts/launch.sh. IRIS_DATA can't live here (templates can't
# expand $HOME), so launch.sh exports it.

PORT=7730
# Loopback only: Caddy (iris.test / iris.mini.<domain>) is the one door.
HOST=127.0.0.1
NODE_ENV=production

# Same service name the server defaults to; host.name says where it runs.
OTEL_SERVICE_NAME=iris-server
OTEL_RESOURCE_ATTRIBUTES=host.name=mini

# APNs (paid team, 2026-11-04): the team-wide token key from the `apple-developer` item. The .p8 field holds the PEM on
# one line (1Password turns its newlines into spaces); `normalizePem` rebuilds it. The topic is the app's bundle id.
APNS_KEY_P8=op://mini/apple-developer/apns-key-p8
APNS_KEY_ID=op://mini/apple-developer/apns-key-id
APNS_TEAM_ID=op://mini/apple-developer/team-id
APNS_TOPIC=com.jkrumm.iris

# The software factory's token API on this machine: the asks and health line for the app, answers forwarded, one push per new
# decision ask. The ref is the one the dotfiles headless refs already carry.
FACTORY_URL=http://127.0.0.1:7793
FACTORY_TOKEN=op://mini/software-factory/FACTORY_TOKEN
