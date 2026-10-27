import { createApp } from "../app.js";
import { createSqliteDeviceStore } from "../adapters/sqlite-devices.js";
import { createSqliteStatsStore } from "../adapters/sqlite-stats.js";
import { createMemoEvents, type MemoEvents } from "../memo/events.js";
import type { HandlerStep } from "../memo/memo.js";
import { createRunner, type StepHandler } from "../memo/runner.js";
import { createMemoMedia } from "../memo/media.js";
import { createMemoService } from "../memo/service.js";
import type { MemoStore } from "../memo/store.js";
import { fakeAudio, testStore } from "../memo/test-support.js";
import type { DestinationName } from "../ports/destination.js";
import type { HerdTab } from "../ports/herd.js";
import { fakeCombiner, fakeHerd, fakeSpeaker, fakeSpeechCache } from "../ports/fakes.js";
import { fakeOtlpExporter } from "../telemetry/fakes.js";
import { createTelemetryRelay } from "../telemetry/relay.js";
import { parseDeviceTokens } from "./auth.js";

export const TOKENS = "tok-phone=iphone,tok-mac=macbook";
export const PHONE = { authorization: "Bearer tok-phone" };
export const MAC = { authorization: "Bearer tok-mac" };

/** The whole server over in-memory SQLite, a fake audio store and a manual clock. */
export function testApp(
  options: {
    /** Step handlers, or a function of the test's store (for `createStepHandlers`). */
    handlers?:
      | Partial<Record<HandlerStep, StepHandler>>
      | ((store: MemoStore) => Partial<Record<HandlerStep, StepHandler>>);
    maxSegmentBytes?: number;
    sseKeepaliveMs?: number;
    /** `false` leaves speech unconfigured (503). */
    speaker?: ReturnType<typeof fakeSpeaker> | false;
    /** `false` leaves herd unconfigured (503). */
    herd?: ReturnType<typeof fakeHerd> | false;
    herdTabs?: HerdTab[];
    combiner?: ReturnType<typeof fakeCombiner>;
    /** The destinations an answer may pick; default `hermes` only. */
    destinations?: DestinationName[];
    /** The collector behind the telemetry relay; default a recording fake, `{down: true}` rejects. */
    otlp?: ReturnType<typeof fakeOtlpExporter>;
    /** `false` leaves the telemetry relay unconfigured (503). */
    telemetry?: false;
  } = {},
) {
  const { store, clock, db } = testStore();
  const base = createMemoEvents();
  let listeners = 0;
  const events: MemoEvents = {
    publish: (e) => base.publish(e),
    subscribe(listener) {
      listeners++;
      const off = base.subscribe(listener);
      return () => {
        listeners--;
        off();
      };
    },
  };
  const audio = fakeAudio();
  const handlers =
    typeof options.handlers === "function" ? options.handlers(store) : (options.handlers ?? {});
  const runner = createRunner({ store, handlers, events, clock });
  const memos = createMemoService({
    store,
    runner,
    events,
    audio,
    clock,
    maxSegmentBytes: options.maxSegmentBytes ?? 1024,
    destinations: options.destinations ?? ["hermes"],
  });
  const devices = createSqliteDeviceStore({ db, clock });
  const combiner = options.combiner ?? fakeCombiner();
  const speaker = options.speaker === false ? undefined : (options.speaker ?? fakeSpeaker());
  const herd =
    options.herd === false
      ? undefined
      : (options.herd ?? fakeHerd(options.herdTabs && { tabs: options.herdTabs }));
  const media = createMemoMedia({
    store,
    audio,
    combiner,
    speaker,
    speechCache: fakeSpeechCache(),
  });
  const otlp = options.otlp ?? fakeOtlpExporter();
  const relayLog: Array<{ event: string; fields: Record<string, unknown> }> = [];
  const telemetry = createTelemetryRelay({
    exporter: otlp,
    log: (event, fields) => relayLog.push({ event, fields }),
  });
  const app = createApp({
    deviceTokens: parseDeviceTokens(TOKENS),
    memos,
    stats: createSqliteStatsStore({ db, clock }),
    devices,
    media,
    herd,
    telemetry: options.telemetry === false ? undefined : telemetry,
    sseKeepaliveMs: options.sseKeepaliveMs,
  });
  return {
    app,
    db,
    store,
    clock,
    events,
    audio,
    runner,
    memos,
    devices,
    combiner,
    speaker,
    herd,
    otlp,
    telemetry,
    relayLog,
    listenerCount: () => listeners,
  };
}

export type TestApp = ReturnType<typeof testApp>["app"];

/** `app.handle` with a JSON body and bearer auth by default. */
export function call(
  app: TestApp,
  params: {
    method?: string;
    path: string;
    headers?: Record<string, string>;
    json?: unknown;
    body?: Uint8Array;
    signal?: AbortSignal;
  },
) {
  const { method = "GET", path, headers = PHONE, json, body, signal } = params;
  return app.handle(
    new Request(`http://iris.test${path}`, {
      method,
      headers: { ...headers, ...(json !== undefined && { "content-type": "application/json" }) },
      ...(json !== undefined && { body: JSON.stringify(json) }),
      ...(body !== undefined && { body }),
      ...(signal && { signal }),
    }),
  );
}

/** Trivial handlers for every step: the pipeline runs transcribe → notify with no external calls. */
export const fakeHandlers: Record<HandlerStep, StepHandler> = {
  transcribe: async () => ({}),
  route: async () => ({}),
  act: async () => ({}),
  summarize: async () => ({}),
  notify: async () => ({}),
};
