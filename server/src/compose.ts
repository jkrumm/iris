import { join } from "node:path";
import { createFsSpeechCache } from "./adapters/speech-fs.js";
import { createAgwSummarizer } from "./adapters/agw.js";
import { createAudioGatewaySpeaker } from "./adapters/audio-gateway-speaker.js";
import { createAudioGatewayTranscriber, ffmpegCombiner } from "./adapters/audio-gateway.js";
import { createHerdrHerd } from "./adapters/herdr.js";
import { createHermesDestination } from "./adapters/hermes.js";
import type { env as parsedEnv } from "./env.js";
import { parseDeviceTokens } from "./http/auth.js";
import { selectNotifier } from "./notify/select.js";
import type { AudioCombiner } from "./ports/audio.js";
import type { Clock } from "./ports/clock.js";
import type { DeviceStore } from "./ports/devices.js";
import type { Destination } from "./ports/destination.js";
import {
  fakeDestination,
  fakeHerd,
  fakeNotifier,
  fakeSpeaker,
  fakeSpeechCache,
  fakeSummarizer,
  fakeTranscriber,
} from "./ports/fakes.js";
import type { Herd, HerdTab } from "./ports/herd.js";
import type { Notifier } from "./ports/notifier.js";
import type { Speaker } from "./ports/speaker.js";
import type { Summarizer } from "./ports/summarizer.js";
import type { Transcriber } from "./ports/transcriber.js";
import { log } from "./telemetry/log.js";

/** The slice of the parsed env the composition reads; every field optional so tests pass literals. */
export type ComposeEnv = Partial<
  Pick<
    typeof parsedEnv,
    | "IRIS_FAKES"
    | "IRIS_DEVICE_TOKENS"
    | "OTEL_EXPORTER_OTLP_ENDPOINT"
    | "AUDIO_GATEWAY_URL"
    | "AGW_URL"
    | "HERMES_URL"
    | "HERMES_TOKEN"
    | "HERDR_SOCKET"
    | "APNS_KEY_P8"
    | "APNS_KEY_ID"
    | "APNS_TEAM_ID"
    | "APNS_TOPIC"
  >
>;

// One MPEG-1 Layer III frame (128 kbps, 44.1 kHz, 417 bytes) of silence: sniffs as audio/mpeg.
const MP3_FRAME = new Uint8Array(417);
MP3_FRAME.set([0xff, 0xfb, 0x90, 0x00]);

const TABS: HerdTab[] = [
  { id: "w1:t1", repo: "example-app", label: "server", agentState: "working", lastActivity: null },
  { id: "w2:t1", repo: "example-infra", label: "1", agentState: "idle", lastActivity: null },
  { id: "w3:t1", repo: "example-docs", label: "2", agentState: "blocked", lastActivity: null },
];

/** Every downstream port as a deterministic in-memory fake (`IRIS_FAKES=1`, see `make e2e`). */
const fakePorts = () => ({
  transcriber: fakeTranscriber(),
  destination: fakeDestination(),
  summarizer: fakeSummarizer(),
  notifier: fakeNotifier(),
  speaker: fakeSpeaker({ result: { bytes: MP3_FRAME } }),
  speechCache: fakeSpeechCache(),
  herd: fakeHerd({ tabs: TABS }),
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
  devices: DeviceStore;
  clock: Clock;
  /** `IRIS_DATA`; the speech cache lives under `<dataDir>/speech`. */
  dataDir: string;
  combiner?: AudioCombiner;
}) {
  const { env, devices, clock, dataDir } = deps;
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

  const ports = {
    transcriber: choose<Transcriber>("transcribe", fakes?.transcriber, () =>
      env.AUDIO_GATEWAY_URL
        ? createAudioGatewayTranscriber({ baseUrl: env.AUDIO_GATEWAY_URL })
        : undefined,
    ),
    destination: choose<Destination>("act", fakes?.destination, () =>
      env.HERMES_URL && env.HERMES_TOKEN
        ? createHermesDestination({ baseUrl: env.HERMES_URL, token: env.HERMES_TOKEN })
        : undefined,
    ),
    summarizer: choose<Summarizer>("summarize", fakes?.summarizer, () =>
      env.AGW_URL ? createAgwSummarizer({ baseUrl: env.AGW_URL }) : undefined,
    ),
    speaker: choose<Speaker>("speech", fakes?.speaker, () =>
      env.AUDIO_GATEWAY_URL
        ? createAudioGatewaySpeaker({ baseUrl: env.AUDIO_GATEWAY_URL })
        : undefined,
    ),
    herd: choose<Herd>("herd", fakes?.herd, () =>
      env.HERDR_SOCKET ? createHerdrHerd({ socketPath: env.HERDR_SOCKET }) : undefined,
    ),
    // Always present, never degraded.
    combiner: deps.combiner ?? ffmpegCombiner,
    speechCache: fakes?.speechCache ?? createFsSpeechCache(join(dataDir, "speech")),
  };

  // APNs when all four APNS_* are set, else the log stand-in (intended until enrolment, so not `degraded`).
  const selected: {
    notifier: Notifier;
    kind: string;
    close?: (() => Promise<void>) | undefined;
  } = fakes
    ? { notifier: fakes.notifier, kind: "fakes" }
    : selectNotifier({ apns: env, devices, clock });
  log("notifier.selected", { kind: selected.kind });

  return {
    ports,
    degraded,
    deviceTokens,
    notifier: selected.notifier,
    notifierKind: selected.kind,
    closeTransport: selected.close,
  };
}
