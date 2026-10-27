import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { createFsAudioStore } from "./adapters/audio-fs.js";
import { createSqliteMemoStore, openDatabase } from "./adapters/sqlite.js";
import { createSqliteDeviceStore } from "./adapters/sqlite-devices.js";
import { createApp } from "./app.js";
import { compose } from "./compose.js";
import { env } from "./env.js";
import { createMemoEvents } from "./memo/events.js";
import { createMemoMedia } from "./memo/media.js";
import { createRunner } from "./memo/runner.js";
import { createMemoService } from "./memo/service.js";
import { createNotifyLifecycle } from "./notify/lifecycle.js";
import { bindPhaseUpdates } from "./notify/phases.js";
import { createStepHandlers } from "./pipeline/steps.js";
import { systemClock } from "./ports/clock.js";
import { log } from "./telemetry/log.js";
import { flushOtel } from "./telemetry/otel.js";

// Production composition: the one place adapters meet ports is `compose`; this file is process concerns.
mkdirSync(env.IRIS_DATA, { recursive: true });
const db = openDatabase(join(env.IRIS_DATA, "iris.db"));
const clock = systemClock;
const store = createSqliteMemoStore({ db, clock });
const devices = createSqliteDeviceStore({ db, clock });
const events = createMemoEvents();
const audio = createFsAudioStore(join(env.IRIS_DATA, "audio"));

// A missing downstream leaves its step without a handler: memos park there and /health says so.
const { ports, degraded, deviceTokens, notifier, closeTransport } = compose({
  env,
  devices,
  clock,
  dataDir: env.IRIS_DATA,
});

const handlers = createStepHandlers({
  store,
  audio,
  transcriber: ports.transcriber,
  destinations: ports.destinations,
  herd: ports.herd,
  decider: ports.decider,
  summarizer: ports.summarizer,
  notifier,
});
log("runner.handlers_registered", { steps: Object.keys(handlers) });
const runner = createRunner({ store, handlers, events, clock });
const notifyLifecycle = createNotifyLifecycle({
  phases: bindPhaseUpdates({ events, store, devices, notifier }),
  closeTransport,
});
const memos = createMemoService({
  store,
  runner,
  events,
  audio,
  clock,
  maxSegmentBytes: env.IRIS_MAX_SEGMENT_BYTES,
});

const media = createMemoMedia({
  store,
  audio,
  combiner: ports.combiner,
  speaker: ports.speaker,
  speechCache: ports.speechCache,
});

const app = createApp({
  deviceTokens,
  degraded,
  memos,
  devices,
  media,
  herd: ports.herd,
  inflight: () => runner.inflightIds().length,
}).listen({
  port: env.PORT,
  hostname: env.HOST,
});

log("server.start", { port: env.PORT, host: env.HOST, degraded });

// Resume memos that were mid-pipeline when the process stopped; never blocks listen.
runner.driveAll().catch((err: unknown) => log("runner.drive_all_failed", { error: String(err) }));

let shuttingDown = false;

// The LaunchAgent's ExitTimeOut (launchd/*.plist.template) must stay above DRAIN_DEADLINE_MS + OTEL_FLUSH_DEADLINE_MS.
const DRAIN_DEADLINE_MS = 30_000;
const OTEL_FLUSH_DEADLINE_MS = 2_000;

const after = (ms: number) =>
  new Promise<"timeout">((resolve) => setTimeout(resolve, ms, "timeout"));

// One idempotent path for signals and crashes: stop accepting, let the running step and the Live
// Activity pushes in flight finish (bounded by one drain deadline), close the APNs transport and the
// DB, then flush OTel under its own short deadline (an
// unreachable collector must not turn a deploy into a hard kill), then exit.
async function shutdown(code: number): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  try {
    await app.stop(true);
    runner.stop();
    notifyLifecycle.stop();
    const drained = await Promise.race([
      Promise.all([runner.idle(), notifyLifecycle.idle()]).then(() => "drained"),
      after(DRAIN_DEADLINE_MS),
    ]);
    if (drained === "timeout") {
      // A step or push is still running: closing the DB would only turn its completion into an error.
      log("shutdown.drain_timeout", { inflight: runner.inflightIds() });
    } else {
      await notifyLifecycle.close();
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
