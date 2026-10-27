import { createApp } from "../app.js";
import { createMemoEvents, type MemoEvents } from "../memo/events.js";
import type { HandlerStep } from "../memo/memo.js";
import { createRunner, type StepHandler } from "../memo/runner.js";
import { createMemoService } from "../memo/service.js";
import { fakeAudio, testStore } from "../memo/test-support.js";
import { parseDeviceTokens } from "./auth.js";

export const TOKENS = "tok-phone=iphone,tok-mac=macbook";
export const PHONE = { authorization: "Bearer tok-phone" };
export const MAC = { authorization: "Bearer tok-mac" };

/** The whole server over in-memory SQLite, a fake audio store and a manual clock. */
export function testApp(
  options: {
    handlers?: Partial<Record<HandlerStep, StepHandler>>;
    maxSegmentBytes?: number;
    sseKeepaliveMs?: number;
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
  const runner = createRunner({ store, handlers: options.handlers ?? {}, events, clock });
  const memos = createMemoService({
    store,
    runner,
    events,
    audio,
    clock,
    maxSegmentBytes: options.maxSegmentBytes ?? 1024,
  });
  const app = createApp({
    deviceTokens: parseDeviceTokens(TOKENS),
    memos,
    sseKeepaliveMs: options.sseKeepaliveMs,
  });
  return { app, db, store, clock, events, audio, runner, memos, listenerCount: () => listeners };
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
