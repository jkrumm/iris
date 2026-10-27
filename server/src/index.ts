import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { createFsAudioStore } from "./adapters/audio-fs.js";
import { createSqliteMemoStore, openDatabase } from "./adapters/sqlite.js";
import { createApp } from "./app.js";
import { env } from "./env.js";
import { parseDeviceTokens } from "./http/auth.js";
import { createMemoEvents } from "./memo/events.js";
import { createRunner } from "./memo/runner.js";
import { createMemoService } from "./memo/service.js";
import { systemClock } from "./ports/clock.js";
import { log } from "./telemetry/log.js";
import { flushOtel } from "./telemetry/otel.js";

const degraded: string[] = [];
if (!env.OTEL_EXPORTER_OTLP_ENDPOINT) degraded.push("otel");

const deviceTokens = parseDeviceTokens(env.IRIS_DEVICE_TOKENS);
if (deviceTokens.size === 0) degraded.push("device-tokens");

// Production composition: the one place adapters meet ports.
mkdirSync(env.IRIS_DATA, { recursive: true });
const db = openDatabase(join(env.IRIS_DATA, "iris.db"));
const clock = systemClock;
const store = createSqliteMemoStore({ db, clock });
const events = createMemoEvents();
// Wave 3 registers the real step handlers; until then memos park after ingest.
const handlers = {};
log("runner.no_handlers_registered", { steps: Object.keys(handlers) });
const runner = createRunner({ store, handlers, events, clock });
const memos = createMemoService({
  store,
  runner,
  events,
  audio: createFsAudioStore(join(env.IRIS_DATA, "audio")),
  clock,
  maxSegmentBytes: env.IRIS_MAX_SEGMENT_BYTES,
});

const app = createApp({ deviceTokens, degraded, memos }).listen({
  port: env.PORT,
  hostname: env.HOST,
});

log("server.start", { port: env.PORT, host: env.HOST, degraded });

// Resume memos that were mid-pipeline when the process stopped; never blocks listen.
runner.driveAll().catch((err: unknown) => log("runner.drive_all_failed", { error: String(err) }));

let shuttingDown = false;

// One idempotent path for signals and crashes: stop accepting, flush OTel under a 2 s deadline
// (an unreachable collector must not turn a deploy into a hard kill), then exit.
async function shutdown(code: number): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  const deadline = new Promise<void>((resolve) => setTimeout(resolve, 2_000));
  await Promise.race([
    app
      .stop(true)
      .then(() => db.close())
      .then(flushOtel),
    deadline,
  ]).catch(() => undefined);
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
