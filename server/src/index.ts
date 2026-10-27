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

let shuttingDown = false;

// One idempotent path for signals and crashes: stop accepting, flush OTel under a 2 s deadline
// (an unreachable collector must not turn a deploy into a hard kill), then exit.
async function shutdown(code: number): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  const deadline = new Promise<void>((resolve) => setTimeout(resolve, 2_000));
  await Promise.race([app.stop().then(flushOtel), deadline]).catch(() => undefined);
  process.exit(code);
}

process.on("SIGTERM", () => void shutdown(0));
process.on("SIGINT", () => void shutdown(0));
process.on("uncaughtException", (err) => {
  log("process.uncaughtException", { error: String(err), stack: err.stack });
  void shutdown(1);
});
process.on("unhandledRejection", (reason) => {
  log("process.unhandledRejection", { error: String(reason) });
  void shutdown(1);
});
