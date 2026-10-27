# Optional overlay: OTLP export to the VPS ingest (-> ClickStack, bearer auth). scripts/launch.sh
# layers it only when both refs resolve; otherwise the server runs with the exporter off and
# /health lists `otel` in `degraded`.
OTEL_EXPORTER_OTLP_ENDPOINT=op://mini/iris/otel-endpoint
OTEL_EXPORTER_OTLP_AUTHORIZATION=op://vps/argo/HYPERDX_API_KEY_PROD
