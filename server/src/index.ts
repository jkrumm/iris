import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { createFsAudioStore } from "./adapters/audio-fs.js";
import { createSqliteMemoStore, openDatabase } from "./adapters/sqlite.js";
import { repairFailedSummaries } from "./adapters/sqlite-repair.js";
import { createSqliteDeviceStore } from "./adapters/sqlite-devices.js";
import { createApp } from "./app.js";
import { compose } from "./compose.js";
import { env } from "./env.js";
import { createMemoEvents } from "./memo/events.js";
import { createMemoMedia } from "./memo/media.js";
import { createPurger } from "./memo/purge.js";
import { createRunner } from "./memo/runner.js";
import { createReplyAssets } from "./memo/reply-assets.js";
import { createMemoService } from "./memo/service.js";
import { createNotifyLifecycle } from "./notify/lifecycle.js";
import { bindNeedsRouteAlerts } from "./notify/needs-route.js";
import { bindPhaseUpdates } from "./notify/phases.js";
import { createStepHandlers } from "./pipeline/steps.js";
import { systemClock } from "./ports/clock.js";
import { registeredDestinations } from "./ports/destination.js";
import { log } from "./telemetry/log.js";
import { flushOtel } from "./telemetry/otel.js";

// Production composition: the one place adapters meet ports is `compose`; this file is process concerns.
mkdirSync(env.IRIS_DATA, { recursive: true });
const db = openDatabase(join(env.IRIS_DATA, "iris.db"));
const clock = systemClock;
const store = createSqliteMemoStore({ db, clock });
// Best effort: a full disk or an existing backup name must not keep the server from booting.
try {
  repairFailedSummaries({ db, clock, dataDir: env.IRIS_DATA });
} catch (err) {
  log("repair.failed_summaries_error", { error: err instanceof Error ? err.message : String(err) });
}
const devices = createSqliteDeviceStore({ db, clock });
const events = createMemoEvents();
const audio = createFsAudioStore(join(env.IRIS_DATA, "audio"));

// A missing downstream leaves its step without a handler: memos park there and /health says so.
const { ports, stats, degraded, deviceTokens, notifier, closeTransport, telemetry } = compose({
  env,
  db,
  devices,
  clock,
  dataDir: env.IRIS_DATA,
});

const replyAssets = createReplyAssets({
  store,
  assets: ports.assets,
  renderer: ports.diagrams,
});

const handlers = createStepHandlers({
  store,
  audio,
  replyAssets,
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
  alerts: bindNeedsRouteAlerts({ events, store, notifier }),
  closeTransport,
});
const memos = createMemoService({
  store,
  runner,
  events,
  audio,
  clock,
  maxSegmentBytes: env.IRIS_MAX_SEGMENT_BYTES,
  destinations: registeredDestinations(ports.destinations ?? {}),
});

const purger = createPurger({
  store,
  audio,
  speechCache: ports.speechCache,
  assets: ports.assets,
  clock,
});

const media = createMemoMedia({
  store,
  audio,
  combiner: ports.combiner,
  speaker: ports.speaker,
  speechCache: ports.speechCache,
  assets: ports.assets,
});

const app = createApp({
  deviceTokens,
  degraded,
  memos,
  stats,
  devices,
  media,
  herd: ports.herd,
  telemetry,
  inflight: () => runner.inflightIds().length,
}).listen({
  port: env.PORT,
  hostname: env.HOST,
});

log("server.start", { port: env.PORT, host: env.HOST, degraded });

// Soft-deleted memos past their undo window: on boot, then every minute.
purger.start();

// Resume memos that were mid-pipeline when the process stopped; never blocks listen.
runner.driveAll().catch((err: unknown) => log("runner.drive_all_failed", { error: String(err) }));

// Replies from before the Mermaid renders (or whose render was lost) get their assets: at most BACKFILL_LIMIT memos per
// start, in this process so it shares the per-memo queue with live renders and the shutdown drain below.
void replyAssets.backfill();
// Files a crash between a commit and its prune left under assets/: at most SWEEP_LIMIT memo directories per start, same queue.
void replyAssets.sweep();

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
    purger.stop();
    // Before the drain: a 50-memo sweep must end after its current memo, not hold the deadline.
    replyAssets.stop();
    notifyLifecycle.stop();
    const drained = await Promise.race([
      Promise.all([runner.idle(), notifyLifecycle.idle(), purger.idle(), replyAssets.idle()]).then(
        () => "drained",
      ),
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
