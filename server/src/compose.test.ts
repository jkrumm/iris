import { describe, expect, it } from "bun:test";
import { createSqliteDeviceStore } from "./adapters/sqlite-devices.js";
import { createApp } from "./app.js";
import { compose, type ComposeEnv } from "./compose.js";
import { call, PHONE } from "./http/test-support.js";
import { createMemoEvents } from "./memo/events.js";
import { createMemoMedia } from "./memo/media.js";
import { createRunner } from "./memo/runner.js";
import { createMemoService } from "./memo/service.js";
import { fakeAudio, testStore } from "./memo/test-support.js";
import { createStepHandlers } from "./pipeline/steps.js";
import { fakeCombiner, type fakeNotifier } from "./ports/fakes.js";

const DEVICE_TOKENS = "tok-phone=iphone";

function build(env: ComposeEnv, combiner = fakeCombiner()) {
  const { store, clock, db } = testStore();
  const devices = createSqliteDeviceStore({ db, clock });
  const composed = compose({ env, devices, clock, dataDir: "/nonexistent/iris-data", combiner });
  return { composed, store, clock, db, devices };
}

function fakesApp() {
  const { composed, store, clock, devices } = build({
    IRIS_FAKES: true,
    IRIS_DEVICE_TOKENS: DEVICE_TOKENS,
  });
  const fakes = {
    ...composed.ports,
    notifier: composed.notifier as ReturnType<typeof fakeNotifier>,
  };
  const events = createMemoEvents();
  const audio = fakeAudio();
  const handlers = createStepHandlers({
    store,
    audio,
    transcriber: fakes.transcriber,
    destinations: fakes.destinations,
    herd: fakes.herd,
    decider: fakes.decider,
    summarizer: fakes.summarizer,
    notifier: fakes.notifier,
  });
  const runner = createRunner({ store, handlers, events, clock });
  const memos = createMemoService({
    store,
    runner,
    events,
    audio,
    clock,
    maxSegmentBytes: 1024,
  });
  const media = createMemoMedia({
    store,
    audio,
    combiner: fakes.combiner,
    speaker: fakes.speaker,
    speechCache: fakes.speechCache,
  });
  const app = createApp({
    deviceTokens: composed.deviceTokens,
    degraded: ["fakes"],
    memos,
    devices,
    media,
    herd: fakes.herd,
  });
  return { app, fakes };
}

describe("compose with IRIS_FAKES", () => {
  it("drives a memo to notified and answers every R1 endpoint", async () => {
    const { app, fakes } = fakesApp();
    const id = crypto.randomUUID();

    const health = await call(app, { path: "/health", headers: {} });
    expect(await health.json()).toMatchObject({ status: "degraded", degraded: ["fakes"] });

    await call(app, {
      method: "POST",
      path: "/v1/memos",
      json: { id, mode: "auto", startedAt: "2026-01-01T00:00:00.000Z" },
    });
    await call(app, {
      method: "PUT",
      path: `/v1/memos/${id}/segments/0`,
      headers: { ...PHONE, "content-type": "audio/mp4" },
      body: new Uint8Array(8).fill(3),
    });
    await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/complete`,
      json: { segmentCount: 1 },
    });

    const result = await call(app, { path: `/v1/memos/${id}/result?wait=5` });
    expect(result.status).toBe(200);
    expect(await result.json()).toMatchObject({ id, state: "notified" });
    expect(fakes.notifier.calls).toHaveLength(1);

    const audio = await call(app, {
      path: `/v1/memos/${id}/audio`,
      headers: { ...PHONE, range: "bytes=0-9" },
    });
    expect(audio.status).toBe(206);

    const speech = await call(app, { path: `/v1/memos/${id}/speech` });
    expect(speech.headers.get("content-type")).toContain("audio/mpeg");
    expect(new Uint8Array(await speech.arrayBuffer()).slice(0, 2)).toEqual(
      new Uint8Array([0xff, 0xfb]),
    );

    const herd = await call(app, { path: "/v1/herd" });
    expect(((await herd.json()) as { tabs: unknown[] }).tabs).toHaveLength(3);

    const register = await call(app, {
      method: "POST",
      path: "/v1/devices/register",
      json: { name: "Test Phone", platform: "ios" },
    });
    expect(register.status).toBe(200);
  });
});

describe("compose", () => {
  it("fakes mode builds every port, ignores downstream env and lists only fakes", () => {
    const { composed } = build({
      IRIS_FAKES: true,
      IRIS_DEVICE_TOKENS: DEVICE_TOKENS,
      OTEL_EXPORTER_OTLP_ENDPOINT: "http://127.0.0.1:4318",
      AUDIO_GATEWAY_URL: "http://127.0.0.1:1",
    });
    const { transcriber, destinations, summarizer, speaker, herd } = composed.ports;
    for (const port of [transcriber, destinations, summarizer, speaker, herd]) {
      expect(port).toBeDefined();
    }
    expect(Object.keys(destinations ?? {}).toSorted()).toEqual(["herdr", "hermes", "journal"]);
    expect(composed.degraded).toEqual(["fakes"]);
    expect(composed.notifierKind).toBe("fakes");
    expect(composed.closeTransport).toBeUndefined();
  });

  it("an empty env builds no downstream and reports each missing one in order", () => {
    const { composed } = build({});
    const { transcriber, destinations, summarizer, speaker, herd } = composed.ports;
    for (const port of [transcriber, destinations, summarizer, speaker, herd]) {
      expect(port).toBeUndefined();
    }
    expect(composed.degraded).toEqual([
      "otel",
      "device-tokens",
      "transcribe",
      "act",
      "summarize",
      "speech",
      "herd",
    ]);
    expect(composed.notifierKind).toBe("log");
    expect(composed.deviceTokens.size).toBe(0);
  });

  it("env URLs build the real adapters without touching the network", () => {
    const { composed } = build({
      OTEL_EXPORTER_OTLP_ENDPOINT: "http://127.0.0.1:1",
      IRIS_DEVICE_TOKENS: DEVICE_TOKENS,
      AUDIO_GATEWAY_URL: "http://127.0.0.1:1",
      AGW_URL: "http://127.0.0.1:1",
      HERMES_URL: "http://127.0.0.1:1",
      HERMES_TOKEN: "token",
      HERDR_SOCKET: "/nonexistent/herdr.sock",
      BRAIN_DIR: "/nonexistent/brain",
    });
    const { transcriber, destinations, summarizer, speaker, herd } = composed.ports;
    for (const port of [transcriber, destinations, summarizer, speaker, herd]) {
      expect(port).toBeDefined();
    }
    expect(composed.degraded).toEqual([]);
    expect(composed.ports.decider).toBeDefined();
    expect(composed.notifierKind).toBe("log");
  });

  it("registers each destination on its own env and turns decide on from two", () => {
    const hermes = { HERMES_URL: "http://127.0.0.1:1", HERMES_TOKEN: "t" };
    const only = (env: ComposeEnv) => {
      const { ports, degraded } = build(env).composed;
      return { names: Object.keys(ports.destinations ?? {}), degraded };
    };

    const one = only(hermes);
    expect(one.names).toEqual(["hermes"]);
    expect(one.degraded).not.toContain("decide");

    const journal = only({ BRAIN_DIR: "/nonexistent/brain" });
    expect(journal.names).toEqual(["journal"]);
    expect(journal.degraded).not.toContain("act");

    const herdr = only({ HERDR_SOCKET: "/nonexistent/herdr.sock" });
    expect(herdr.names).toEqual(["herdr"]);
    expect(herdr.degraded).not.toContain("act");
    expect(herdr.degraded).not.toContain("herd");

    const several = only({ ...hermes, BRAIN_DIR: "/nonexistent/brain" });
    expect(several.names.toSorted()).toEqual(["hermes", "journal"]);
    expect(several.degraded).toContain("decide");

    const withDecider = build({
      ...hermes,
      BRAIN_DIR: "/nonexistent/brain",
      AGW_URL: "http://127.0.0.1:1",
    }).composed;
    expect(withDecider.degraded).not.toContain("decide");
    expect(withDecider.ports.decider).toBeDefined();
  });

  it("Hermes needs both its URL and token", () => {
    const { composed } = build({ HERMES_URL: "http://127.0.0.1:1" });
    expect(composed.ports.destinations).toBeUndefined();
    expect(composed.degraded).toContain("act");
  });
});
