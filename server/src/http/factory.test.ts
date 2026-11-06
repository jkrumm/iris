import { describe, expect, it } from "bun:test";
import { createApp } from "../app.js";
import { decisionAsk } from "../factory/test-support.js";
import { createFactoryService } from "../factory/service.js";
import { MemoError } from "../memo/errors.js";
import { FactoryError } from "../ports/factory.js";
import { fakeFactoryReader } from "../ports/fakes.js";
import { parseDeviceTokens } from "./auth.js";
import { call, MAC, testApp, TOKENS, type TestApp } from "./test-support.js";

const queueAsk = decisionAsk({
  id: "hc:1",
  source: "queue",
  issue: null,
  short: "Review the PR",
  summary: "A PR waits for you.",
});

function setup() {
  const factory = fakeFactoryReader({
    asks: [decisionAsk(), queueAsk],
    health: [
      {
        id: "h1",
        kind: "park",
        short: "Parked",
        summary: "One Issue is parked.",
        since: "2026-11-06T08:00:00.000Z",
      },
    ],
    options: { 113: ["Keep Redis", "Drop it"] },
  });
  return { factory, ...testApp({ factory }) };
}

describe("GET /v1/factory", () => {
  it("serves asks with answerable and options, the health line and the counts", async () => {
    const { app } = setup();
    const res = await call(app, { path: "/v1/factory" });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      asks: [
        { ...decisionAsk(), answerable: true, options: ["Keep Redis", "Drop it"] },
        { ...queueAsk, answerable: false, options: [] },
      ],
      health: [
        {
          id: "h1",
          kind: "park",
          short: "Parked",
          summary: "One Issue is parked.",
          since: "2026-11-06T08:00:00.000Z",
        },
      ],
      counts: { asks: 2, health: 1 },
      builtAt: "2026-11-06T10:00:00.000Z",
    });
  });

  it("still lists an ask when its options cannot be read", async () => {
    const { app, factory } = setup();
    factory.state.optionsFailWith = new FactoryError("not_found", "no such issue");
    const body = (await (await call(app, { path: "/v1/factory" })).json()) as {
      asks: { options: string[] }[];
    };
    expect(body.asks[0]?.options).toEqual([]);
  });

  it("503s when the factory is unreachable, and when it is not configured", async () => {
    const { app, factory } = setup();
    factory.state.failWith = new FactoryError("unavailable", "down");
    const down = await call(app, { path: "/v1/factory" });
    expect(down.status).toBe(503);
    expect(await down.json()).toEqual({
      error: "unavailable",
      message: "the factory is unreachable",
    });

    const bare = testApp().app;
    const res = await call(bare, { path: "/v1/factory" });
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({
      error: "unavailable",
      message: "factory is not configured",
    });
  });

  it("401s without a device token", async () => {
    const { app } = setup();
    expect((await call(app, { path: "/v1/factory", headers: {} })).status).toBe(401);
    expect(
      (await call(app, { method: "POST", path: "/v1/factory/answer", headers: {}, json: {} }))
        .status,
    ).toBe(401);
  });
});

describe("POST /v1/factory/answer", () => {
  const body = (patch: object = {}) => ({
    askId: decisionAsk().id,
    text: "  Keep Redis ",
    callId: "call-1",
    ...patch,
  });

  it("forwards the trimmed answer to the Issue of the current ask, with the call id", async () => {
    const { app, factory } = setup();
    const res = await call(app, { method: "POST", path: "/v1/factory/answer", json: body() });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ issue: 113, state: "working", duplicate: false });
    expect(factory.answers).toEqual([{ issue: 113, callId: "call-1", text: "Keep Redis" }]);

    const retry = await call(app, {
      method: "POST",
      path: "/v1/factory/answer",
      headers: MAC,
      json: body(),
    });
    expect(await retry.json()).toMatchObject({ duplicate: true });
  });

  it("404s when the ask is gone", async () => {
    const { app, factory } = setup();
    const res = await call(app, {
      method: "POST",
      path: "/v1/factory/answer",
      json: body({ askId: "decision:1:1:ask:none" }),
    });
    expect(res.status).toBe(404);
    expect(await res.json()).toMatchObject({ error: "not_found" });
    expect(factory.answers).toEqual([]);
  });

  it("409s for an ask that is not a decision, and when the factory has no open question", async () => {
    const { app, factory } = setup();
    const notDecision = await call(app, {
      method: "POST",
      path: "/v1/factory/answer",
      json: body({ askId: "hc:1" }),
    });
    expect(notDecision.status).toBe(409);
    expect(await notDecision.json()).toMatchObject({ error: "bad_state" });

    factory.state.answerFailWith = new FactoryError("conflict", "no open question");
    const closed = await call(app, { method: "POST", path: "/v1/factory/answer", json: body() });
    expect(closed.status).toBe(409);
    expect(await closed.json()).toEqual({
      error: "bad_state",
      message: "the factory has no open question on this Issue",
    });
  });

  it("503s when the factory is down", async () => {
    const { app, factory } = setup();
    factory.state.answerFailWith = new FactoryError("unavailable", "down");
    expect(
      (await call(app, { method: "POST", path: "/v1/factory/answer", json: body() })).status,
    ).toBe(503);
  });

  it.each([
    ["a blank answer", { text: "   " }],
    ["a one-character answer", { text: "x" }],
    ["a call id with a bad character", { callId: "bad id" }],
    ["a call id that starts with a dot", { callId: ".x" }],
    ["an empty ask id", { askId: "" }],
    ["a 2001-character answer", { text: "x".repeat(2001) }],
  ])("400s on %s", async (_, patch) => {
    const { app } = setup();
    const res = await call(app, { method: "POST", path: "/v1/factory/answer", json: body(patch) });
    expect(res.status).toBe(400);
    expect(await res.json()).toMatchObject({ error: "bad_request" });
  });

  it("503s when unconfigured", async () => {
    const { memos } = testApp();
    const app = createApp({ deviceTokens: parseDeviceTokens(TOKENS), memos }) as unknown as TestApp;
    const res = await call(app, { method: "POST", path: "/v1/factory/answer", json: body() });
    expect(res.status).toBe(503);
  });
});

describe("factory service", () => {
  it("maps a foreign error through untouched", async () => {
    const reader = fakeFactoryReader();
    reader.state.failWith = new Error("bug");
    const service = createFactoryService({ reader });
    expect(await service.view().catch((e: unknown) => e)).not.toBeInstanceOf(MemoError);
  });
});
