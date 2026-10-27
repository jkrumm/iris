import { createApp } from "./app.js";
import { env } from "./env.js";
import { parseDeviceTokens } from "./http/auth.js";
import { log } from "./telemetry/log.js";
import { flushOtel } from "./telemetry/otel.js";

const degraded: string[] = [];
if (!env.OTEL_EXPORTER_OTLP_ENDPOINT) degraded.push("otel");

const deviceTokens = parseDeviceTokens(env.IRIS_DEVICE_TOKENS);
if (deviceTokens.size === 0) degraded.push("device-tokens");

const app = createApp({ deviceTokens, degraded }).listen({
  port: env.PORT,
  hostname: env.HOST,
});

log("server.start", { port: env.PORT, host: env.HOST, degraded });

function shutdown(code: number): void {
  const deadline = new Promise<void>((resolve) => setTimeout(resolve, 2_000));
  void Promise.race([flushOtel(), deadline]).finally(() => process.exit(code));
}
process.on("SIGTERM", () => {
  void app.stop();
  shutdown(0);
});
process.on("SIGINT", () => {
  void app.stop();
  shutdown(0);
});
