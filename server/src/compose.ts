import type { Database } from "bun:sqlite";
import { join } from "node:path";
import { createFsAssetStore } from "./adapters/assets-fs.js";
import { createPeleRenderer } from "./adapters/diagram-pele.js";
import { createFsSpeechCache } from "./adapters/speech-fs.js";
import { createAgwClient } from "./adapters/agw-client.js";
import { createAgwSummarizer } from "./adapters/agw.js";
import { createAudioDoorClient } from "./adapters/audio-door-client.js";
import { createAudioDoorSpeaker } from "./adapters/audio-door-speaker.js";
import { createAudioDoorTranscriber, ffmpegCombiner } from "./adapters/audio-door.js";
import { createFactoryHttp } from "./adapters/factory-http.js";
import { createHermesDestination } from "./adapters/hermes.js";
import { createSqliteStatsStore } from "./adapters/sqlite-stats.js";
import type { env as parsedEnv } from "./env.js";
import { parseDeviceTokens } from "./http/auth.js";
import { selectNotifier } from "./notify/select.js";
import type { AudioCombiner } from "./ports/audio.js";
import type { Clock } from "./ports/clock.js";
import type { DeviceStore } from "./ports/devices.js";
import type { Destination } from "./ports/destination.js";
import {
  fakeAssetStore,
  fakeDiagramRenderer,
  fakeDestination,
  fakeFactoryAlerter,
  fakeFactoryReader,
  fakeNotifier,
  fakeSpeaker,
  fakeSpeechCache,
  fakeSummarizer,
  fakeTranscriber,
} from "./ports/fakes.js";
import type { FactoryAlerter, FactoryReader } from "./ports/factory.js";
import type { Notifier } from "./ports/notifier.js";
import type { Speaker } from "./ports/speaker.js";
import type { Summarizer } from "./ports/summarizer.js";
import type { Transcriber } from "./ports/transcriber.js";
import { fakeOtlpExporter } from "./telemetry/fakes.js";
import { log } from "./telemetry/log.js";
import { exportOtlp } from "./telemetry/otel.js";
import { createTelemetryRelay } from "./telemetry/relay.js";

/** The slice of the parsed env the composition reads; every field optional so tests pass literals. */
export type ComposeEnv = Partial<
  Pick<
    typeof parsedEnv,
    | "IRIS_FAKES"
    | "IRIS_DEVICE_TOKENS"
    | "OTEL_EXPORTER_OTLP_ENDPOINT"
    | "AUDIO_DOOR_URL"
    | "AUDIO_DOOR_TOKEN"
    | "AGW_URL"
    | "AGW_API_SECRET"
    | "FACTORY_URL"
    | "FACTORY_TOKEN"
    | "HERMES_URL"
    | "HERMES_TOKEN"
    | "APNS_KEY_P8"
    | "APNS_KEY_ID"
    | "APNS_TEAM_ID"
    | "APNS_TOPIC"
  >
>;

// One MPEG-1 Layer III frame (128 kbps, 44.1 kHz, 417 bytes) of silence: sniffs as audio/mpeg.
const MP3_FRAME = new Uint8Array(417);
MP3_FRAME.set([0xff, 0xfb, 0x90, 0x00]);

/** Every downstream port as a deterministic in-memory fake (`IRIS_FAKES=1`, see `make e2e`). */
const fakePorts = () => ({
  transcriber: fakeTranscriber(),
  // Like Hermes: a session per memo, and (as the `iris` skill would) a kind, a headline and two tool names.
  destination: fakeDestination({ sessionPerMemo: true }),
  summarizer: fakeSummarizer(),
  notifier: fakeNotifier(),
  factory: fakeFactoryReader(),
  factoryAlerter: fakeFactoryAlerter(),
  speaker: fakeSpeaker({ result: { bytes: MP3_FRAME } }),
  speechCache: fakeSpeechCache(),
  assets: fakeAssetStore(),
  diagrams: fakeDiagramRenderer(),
  otlp: fakeOtlpExporter(),
});

/**
 * The one place a downstream port is chosen: a fake (`IRIS_FAKES`), the real adapter (its env is
 * set) or nothing, which leaves the step without a handler and adds its name to `degraded`.
 * Adapters only build clients here, they make no network call. A new port is one line in the
 * `ports` object below, one in `fakePorts`, and its env var in `env.ts`.
 *
 * The combiner is real ffmpeg even in fakes mode, so `/audio` serves genuine m4a with working
 * Range; tests inject a fake one.
 */
export function compose(deps: {
  env: ComposeEnv;
  /** The memo database: the read-only stats store is built over it (always, fakes mode included). */
  db: Database;
  devices: DeviceStore;
  clock: Clock;
  /** `IRIS_DATA`; the speech cache lives under `<dataDir>/speech`, reply assets under `<dataDir>/assets`. */
  dataDir: string;
  combiner?: AudioCombiner;
}) {
  const { env, db, devices, clock, dataDir } = deps;
  const degraded: string[] = [];
  if (!env.OTEL_EXPORTER_OTLP_ENDPOINT) degraded.push("otel");

  const fakes = env.IRIS_FAKES ? fakePorts() : undefined;
  if (fakes) {
    degraded.push("fakes");
    log("server.fakes_mode", { warning: "ALL DOWNSTREAMS ARE FAKES: NOT FOR PRODUCTION" });
  }

  const deviceTokens = parseDeviceTokens(env.IRIS_DEVICE_TOKENS ?? "");
  if (deviceTokens.size === 0) degraded.push("device-tokens");

  /** The fake in fakes mode, else `real()`; a missing port is recorded in `degraded` under `name`. */
  const choose = <T>(name: string, fake: T | undefined, real: () => T | undefined) => {
    const port = fake ?? real();
    if (!port) degraded.push(name);
    return port;
  };

  // The door needs its URL and its token together; STT and TTS share the one client.
  const audioDoor =
    env.AUDIO_DOOR_URL && env.AUDIO_DOOR_TOKEN
      ? createAudioDoorClient({ baseUrl: env.AUDIO_DOOR_URL, token: env.AUDIO_DOOR_TOKEN })
      : undefined;

  // The host needs its URL and its bearer together.
  const agw =
    env.AGW_URL && env.AGW_API_SECRET
      ? createAgwClient({ baseUrl: env.AGW_URL, secret: env.AGW_API_SECRET })
      : undefined;

  const ports = {
    transcriber: choose<Transcriber>("transcribe", fakes?.transcriber, () =>
      audioDoor ? createAudioDoorTranscriber({ client: audioDoor }) : undefined,
    ),
    // Hermes is the one destination; `act` is degraded without it.
    destination: choose<Destination>("act", fakes?.destination, () =>
      env.HERMES_URL && env.HERMES_TOKEN
        ? createHermesDestination({ baseUrl: env.HERMES_URL, token: env.HERMES_TOKEN })
        : undefined,
    ),
    summarizer: choose<Summarizer>("summarize", fakes?.summarizer, () =>
      agw ? createAgwSummarizer({ client: agw }) : undefined,
    ),
    speaker: choose<Speaker>("speech", fakes?.speaker, () =>
      audioDoor ? createAudioDoorSpeaker({ client: audioDoor }) : undefined,
    ),
    // Always present, never degraded.
    combiner: deps.combiner ?? ffmpegCombiner,
    speechCache: fakes?.speechCache ?? createFsSpeechCache(join(dataDir, "speech")),
    assets: fakes?.assets ?? createFsAssetStore(join(dataDir, "assets")),
    diagrams: fakes?.diagrams ?? createPeleRenderer(),
  };

  // The factory's read API needs its URL and its bearer together.
  const factory = choose<FactoryReader>("factory", fakes?.factory, () =>
    env.FACTORY_URL && env.FACTORY_TOKEN
      ? createFactoryHttp({ baseUrl: env.FACTORY_URL, token: env.FACTORY_TOKEN })
      : undefined,
  );

  // APNs when all four APNS_* are set, else the log stand-in (a dev setup, so not `degraded`).
  const selected: {
    notifier: Notifier;
    kind: string;
    factoryAlerter: FactoryAlerter;
    close?: (() => Promise<void>) | undefined;
  } = fakes
    ? { notifier: fakes.notifier, kind: "fakes", factoryAlerter: fakes.factoryAlerter }
    : selectNotifier({ apns: env, devices, clock });
  log("notifier.selected", { kind: selected.kind });

  // Always present, never degraded: with no OTLP endpoint (already `otel` in `degraded`) the exporter is a no-op.
  const telemetry = createTelemetryRelay({ exporter: fakes?.otlp ?? { send: exportOtlp } });

  return {
    ports,
    stats: createSqliteStatsStore({ db, clock }),
    telemetry,
    degraded,
    deviceTokens,
    notifier: selected.notifier,
    factory,
    factoryAlerter: selected.factoryAlerter,
    notifierKind: selected.kind,
    closeTransport: selected.close,
  };
}
