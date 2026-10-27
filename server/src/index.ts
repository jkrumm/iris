import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { createFsAudioStore } from "./adapters/audio-fs.js";
import { createAudioGatewayTranscriber } from "./adapters/audio-gateway.js";
import { createAgwSummarizer } from "./adapters/agw.js";
import { createHermesDestination } from "./adapters/hermes.js";
import { createLogNotifier } from "./adapters/notifier-log.js";
import { createSqliteMemoStore, openDatabase } from "./adapters/sqlite.js";
import { createApp } from "./app.js";
import { env } from "./env.js";
import { parseDeviceTokens } from "./http/auth.js";
import { createMemoEvents } from "./memo/events.js";
import { createRunner } from "./memo/runner.js";
import { createMemoService } from "./memo/service.js";
import { createStepHandlers } from "./pipeline/steps.js";
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
const audio = createFsAudioStore(join(env.IRIS_DATA, "audio"));

// A missing downstream leaves its step without a handler: memos park there and /health says so.
const transcriber = env.AUDIO_GATEWAY_URL
  ? createAudioGatewayTranscriber({ baseUrl: env.AUDIO_GATEWAY_URL })
  : undefined;
if (!transcriber) degraded.push("transcribe");
const destination =
  env.HERMES_URL && env.HERMES_TOKEN
    ? createHermesDestination({ baseUrl: env.HERMES_URL, token: env.HERMES_TOKEN })
    : undefined;
if (!destination) degraded.push("act");
const summarizer = env.AGW_URL ? createAgwSummarizer({ baseUrl: env.AGW_URL }) : undefined;
if (!summarizer) degraded.push("summarize");

const handlers = createStepHandlers({
  store,
  audio,
  transcriber,
  destination,
  summarizer,
  notifier: createLogNotifier(),
});
log("runner.handlers_registered", { steps: Object.keys(handlers) });
const runner = createRunner({ store, handlers, events, clock });
const memos = createMemoService({
  store,
  runner,
  events,
  audio,
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

// Wave 4's LaunchAgent must set ExitTimeOut above DRAIN_DEADLINE_MS + OTEL_FLUSH_DEADLINE_MS (>= 45 s).
const DRAIN_DEADLINE_MS = 30_000;
const OTEL_FLUSH_DEADLINE_MS = 2_000;

const after = (ms: number) =>
  new Promise<"timeout">((resolve) => setTimeout(resolve, ms, "timeout"));

// One idempotent path for signals and crashes: stop accepting, let the running step finish (bounded
// by the drain deadline), close the DB, then flush OTel under its own short deadline (an
// unreachable collector must not turn a deploy into a hard kill), then exit.
async function shutdown(code: number): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  try {
    await app.stop(true);
    runner.stop();
    const drained = await Promise.race([
      runner.idle().then(() => "drained"),
      after(DRAIN_DEADLINE_MS),
    ]);
    if (drained === "timeout") {
      // A step is still running: closing the DB would only turn its completion into an error.
      log("shutdown.drain_timeout", { inflight: runner.inflightIds() });
    } else {
      db.close();
    }
  } catch (err) {
    log("shutdown.failed", { error: String(err) });
  }
  await Promise.race([flushOtel(), after(OTEL_FLUSH_DEADLINE_MS)]).catch(() => undefined);
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
