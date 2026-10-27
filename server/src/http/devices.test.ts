import { describe, expect, it } from "bun:test";
import { seedMemo } from "../memo/test-support.js";
import { createApp } from "../app.js";
import { call, MAC, TOKENS, testApp } from "./test-support.js";
import { parseDeviceTokens } from "./auth.js";

const register = (
  app: ReturnType<typeof testApp>["app"],
  json: unknown,
  headers?: Record<string, string>,
) =>
  call(app, {
    method: "POST",
    path: "/v1/devices/register",
    json,
    ...(headers && { headers }),
  });

describe("POST /v1/devices/register", () => {
  it("registers under the authenticated device, not the body name", async () => {
    const { app, devices } = testApp();
    const res = await register(app, {
      name: "Test iPhone",
      platform: "ios",
      apnsToken: "aa11",
      apnsEnv: "sandbox",
      pushToStartToken: "bb22",
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      device: "iphone",
      name: "Test iPhone",
      platform: "ios",
      apnsEnv: "sandbox",
      hasApnsToken: true,
      hasPushToStartToken: true,
      registeredAt: "2026-01-01T00:00:00.000Z",
    });
    expect(devices.getDevice("iphone")).toMatchObject({
      apnsToken: "aa11",
      pushToStartToken: "bb22",
    });
    expect(devices.getDevice("Test iPhone")).toBeNull();
  });

  it("keeps stored tokens when omitted or empty and clears them on null", async () => {
    const { app, devices } = testApp();
    await register(app, {
      name: "p",
      platform: "ios",
      apnsToken: "aa11",
      pushToStartToken: "bb22",
    });

    await register(app, { name: "p", platform: "ios", apnsToken: "" });
    expect(devices.getDevice("iphone")).toMatchObject({
      apnsToken: "aa11",
      pushToStartToken: "bb22",
    });

    const res = await register(app, { name: "p", platform: "ios", pushToStartToken: null });
    expect(await res.json()).toMatchObject({ hasApnsToken: true, hasPushToStartToken: false });
    expect(devices.getDevice("iphone")?.pushToStartToken).toBeNull();
  });

  it("registers each authenticated device separately", async () => {
    const { app, devices } = testApp();
    await register(app, { name: "phone", platform: "ios" });
    await register(app, { name: "mac", platform: "macos" }, MAC);
    expect(devices.listDevices().map((d) => [d.device, d.platform])).toEqual([
      ["iphone", "ios"],
      ["macbook", "macos"],
    ]);
  });

  it("400s an unknown platform, an unknown apnsEnv and a missing name", async () => {
    const { app } = testApp();
    for (const json of [
      { name: "p", platform: "android" },
      { name: "p", platform: "ios", apnsEnv: "staging" },
      { platform: "ios" },
      { name: "", platform: "ios" },
    ]) {
      const res = await register(app, json);
      expect(res.status).toBe(400);
      expect(await res.json()).toMatchObject({ error: "bad_request" });
    }
  });

  it("401s without a token", async () => {
    const { app } = testApp();
    expect((await register(app, { name: "p", platform: "ios" }, {})).status).toBe(401);
  });

  it("503s when no device store is configured", async () => {
    const { memos } = testApp();
    const bare = createApp({ deviceTokens: parseDeviceTokens(TOKENS), memos });
    const res = await register(bare, { name: "p", platform: "ios" });
    expect(res.status).toBe(503);
    expect(await res.json()).toMatchObject({ error: "unavailable" });
  });
});

const put = (app: ReturnType<typeof testApp>["app"], id: string, json: unknown) =>
  call(app, { method: "PUT", path: `/v1/memos/${id}/activity-token`, json });

describe("PUT /v1/memos/:id/activity-token", () => {
  it("stores the token with 204 and replaces it when it rotates", async () => {
    const { app, store, devices } = testApp();
    const { id } = seedMemo(store);
    const first = await put(app, id, { token: "aabbcc" });
    expect(first.status).toBe(204);
    expect(await first.text()).toBe("");
    expect(devices.getActivityToken(id)).toBe("aabbcc");

    expect((await put(app, id, { token: "DDEEFF" })).status).toBe(204);
    expect(devices.getActivityToken(id)).toBe("DDEEFF");
  });

  it("404s an unknown memo", async () => {
    const { app } = testApp();
    const res = await put(app, crypto.randomUUID(), { token: "aa" });
    expect(res.status).toBe(404);
    expect(await res.json()).toMatchObject({ error: "not_found" });
  });

  it("400s a token that is not hex or is missing", async () => {
    const { app, store, devices } = testApp();
    const { id } = seedMemo(store);
    for (const json of [{ token: "xyz" }, { token: "" }, {}, { token: 12 }]) {
      expect((await put(app, id, json)).status).toBe(400);
    }
    expect(devices.getActivityToken(id)).toBeNull();
  });
});
