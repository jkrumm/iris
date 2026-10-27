import { describe, expect, it } from "bun:test";
import { createApp } from "../app.js";
import { parseDeviceTokens } from "./auth.js";
import { call, testApp, TOKENS, type TestApp } from "./test-support.js";

describe("GET /v1/stats", () => {
  it("defaults to 30 days and answers an empty window", async () => {
    const { app } = testApp();
    const res = await call(app, { path: "/v1/stats" });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { days: number; from: string; to: string };
    expect(body).toMatchObject({
      days: 30,
      perDay: [],
      perWeek: [],
      stepMedians: [],
      costPerRoute: [],
    });
    expect(body.from < body.to).toBe(true);
  });

  it("aggregates memos created through the store", async () => {
    const { app, store } = testApp();
    store.createMemo({
      id: "11111111-1111-4111-8111-111111111111",
      mode: "auto",
      device: "iphone",
      startedAt: "2026-01-01T00:00:00.000Z",
    });
    const res = await call(app, { path: "/v1/stats?days=1" });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { days: number; perDay: { route: string; count: number }[] };
    expect(body.days).toBe(1);
    expect(body.perDay).toEqual([expect.objectContaining({ route: "unrouted", count: 1 })]);
  });

  it.each(["0", "366", "1.5", "-3", "abc"])("400s on days=%s", async (days) => {
    const { app } = testApp();
    const res = await call(app, { path: `/v1/stats?days=${days}` });
    expect(res.status).toBe(400);
    expect(await res.json()).toMatchObject({ error: "bad_request" });
  });

  it.each(["1", "365"])("accepts the bound days=%s", async (days) => {
    const { app } = testApp();
    expect((await call(app, { path: `/v1/stats?days=${days}` })).status).toBe(200);
  });

  it("503s when the app is composed without a stats store", async () => {
    const { memos } = testApp();
    const app = createApp({ deviceTokens: parseDeviceTokens(TOKENS), memos }) as unknown as TestApp;
    const res = await call(app, { path: "/v1/stats" });
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "unavailable", message: "stats is not configured" });
  });

  it("401s without a token", async () => {
    const { app } = testApp();
    expect((await call(app, { path: "/v1/stats", headers: {} })).status).toBe(401);
  });
});
