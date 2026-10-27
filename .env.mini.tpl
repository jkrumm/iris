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
