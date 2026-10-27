import { describe, expect, it } from "bun:test";
import { createSqliteDeviceStore } from "./adapters/sqlite-devices.js";
import { createApp } from "./app.js";
import { composeFakes } from "./compose-fakes.js";
import { parseDeviceTokens } from "./http/auth.js";
import { call, PHONE } from "./http/test-support.js";
import { createMemoEvents } from "./memo/events.js";
import { createMemoMedia } from "./memo/media.js";
import { createRunner } from "./memo/runner.js";
import { createMemoService } from "./memo/service.js";
import { fakeAudio, testStore } from "./memo/test-support.js";
import { createStepHandlers } from "./pipeline/steps.js";
import { fakeCombiner } from "./ports/fakes.js";

function fakesApp() {
  const fakes = composeFakes({ combiner: fakeCombiner() });
  const { store, clock, db } = testStore();
  const events = createMemoEvents();
  const audio = fakeAudio();
  const handlers = createStepHandlers({
    store,
    audio,
    transcriber: fakes.transcriber,
    destination: fakes.destination,
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
    deviceTokens: parseDeviceTokens("tok-phone=iphone"),
    degraded: ["fakes"],
    memos,
    devices: createSqliteDeviceStore({ db, clock }),
    media,
    herd: fakes.herd,
  });
  return { app, fakes };
}

describe("composeFakes", () => {
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
