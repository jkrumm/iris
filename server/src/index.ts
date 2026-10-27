import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { createFsAudioStore } from "./adapters/audio-fs.js";
import { createAudioGatewayTranscriber, ffmpegCombiner } from "./adapters/audio-gateway.js";
import { createAudioGatewaySpeaker } from "./adapters/audio-gateway-speaker.js";
import { createAgwSummarizer } from "./adapters/agw.js";
import { createHerdrHerd } from "./adapters/herdr.js";
import { createHermesDestination } from "./adapters/hermes.js";
import { createSqliteMemoStore, openDatabase } from "./adapters/sqlite.js";
import { createSqliteDeviceStore } from "./adapters/sqlite-devices.js";
import { createFsSpeechCache } from "./adapters/speech-fs.js";
import { createApp } from "./app.js";
import { composeFakes } from "./compose-fakes.js";
import { env } from "./env.js";
import { parseDeviceTokens } from "./http/auth.js";
import { createMemoEvents } from "./memo/events.js";
import { createMemoMedia } from "./memo/media.js";
import { createRunner } from "./memo/runner.js";
import { createMemoService } from "./memo/service.js";
import { bindPhaseUpdates } from "./notify/phases.js";
import { selectNotifier } from "./notify/select.js";
import { createStepHandlers } from "./pipeline/steps.js";
import { systemClock } from "./ports/clock.js";
import { log } from "./telemetry/log.js";
import { flushOtel } from "./telemetry/otel.js";

const degraded: string[] = [];
if (!env.OTEL_EXPORTER_OTLP_ENDPOINT) degraded.push("otel");

// IRIS_FAKES=1 (make e2e): every downstream port is an in-memory fake; env URLs and tokens are ignored.
const fakes = env.IRIS_FAKES ? composeFakes() : undefined;
if (fakes) {
  degraded.push("fakes");
  log("server.fakes_mode", { warning: "ALL DOWNSTREAMS ARE FAKES: NOT FOR PRODUCTION" });
}

const deviceTokens = parseDeviceTokens(env.IRIS_DEVICE_TOKENS);
if (deviceTokens.size === 0) degraded.push("device-tokens");

// Production composition: the one place adapters meet ports.
mkdirSync(env.IRIS_DATA, { recursive: true });
const db = openDatabase(join(env.IRIS_DATA, "iris.db"));
const clock = systemClock;
const store = createSqliteMemoStore({ db, clock });
const devices = createSqliteDeviceStore({ db, clock });
const events = createMemoEvents();
const audio = createFsAudioStore(join(env.IRIS_DATA, "audio"));

// A missing downstream leaves its step without a handler: memos park there and /health says so.
const transcriber = fakes
  ? fakes.transcriber
  : env.AUDIO_GATEWAY_URL
    ? createAudioGatewayTranscriber({ baseUrl: env.AUDIO_GATEWAY_URL })
    : undefined;
if (!transcriber) degraded.push("transcribe");
const destination = fakes
  ? fakes.destination
  : env.HERMES_URL && env.HERMES_TOKEN
    ? createHermesDestination({ baseUrl: env.HERMES_URL, token: env.HERMES_TOKEN })
    : undefined;
if (!destination) degraded.push("act");
const summarizer = fakes
  ? fakes.summarizer
  : env.AGW_URL
    ? createAgwSummarizer({ baseUrl: env.AGW_URL })
    : undefined;
if (!summarizer) degraded.push("summarize");

const speaker = fakes
  ? fakes.speaker
  : env.AUDIO_GATEWAY_URL
    ? createAudioGatewaySpeaker({ baseUrl: env.AUDIO_GATEWAY_URL })
    : undefined;
if (!speaker) degraded.push("speech");
const herd = fakes
  ? fakes.herd
  : env.HERDR_SOCKET
    ? createHerdrHerd({ socketPath: env.HERDR_SOCKET })
    : undefined;
if (!herd) degraded.push("herd");

// APNs when all four APNS_* are set, else the log stand-in (intended until enrolment, so not `degraded`).
const { notifier, kind: notifierKind } = fakes
  ? { notifier: fakes.notifier, kind: "fakes" }
  : selectNotifier({ apns: env, devices, clock });
log("notifier.selected", { kind: notifierKind });

const handlers = createStepHandlers({
  store,
  audio,
  transcriber,
  destination,
  summarizer,
  notifier,
});
log("runner.handlers_registered", { steps: Object.keys(handlers) });
const runner = createRunner({ store, handlers, events, clock });
bindPhaseUpdates({ events, store, devices, notifier });
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
  combiner: fakes ? fakes.combiner : ffmpegCombiner,
  speaker,
  speechCache: fakes ? fakes.speechCache : createFsSpeechCache(join(env.IRIS_DATA, "speech")),
});

const app = createApp({
  deviceTokens,
  degraded,
  memos,
  devices,
  media,
  herd,
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
