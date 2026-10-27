import { describe, expect, it } from "bun:test";
import { createApp } from "../app.js";
import { deviceForToken, parseDeviceTokens } from "./auth.js";
import { testApp } from "./test-support.js";

const tokens = parseDeviceTokens("tok-phone=iphone, tok-mac=macbook");
const { memos, app } = testApp();
const get = (path: string, auth?: string) =>
  app.handle(
    new Request(`http://iris.test${path}`, auth ? { headers: { authorization: auth } } : {}),
  );

describe("parseDeviceTokens", () => {
  it("parses pairs and skips malformed entries", () => {
    const parsed = parseDeviceTokens("a=one,,=x,b=,noeq, c = three=3 ");
    expect([...parsed]).toEqual([
      ["a", "one"],
      ["c", "three=3"],
    ]);
  });

  it("returns an empty map for an empty string", () => {
    expect(parseDeviceTokens("").size).toBe(0);
  });
});

describe("deviceForToken", () => {
  it("resolves known tokens and rejects unknown ones of any length", () => {
    expect(deviceForToken(tokens, "tok-mac")).toBe("macbook");
    expect(deviceForToken(tokens, "tok-mac-and-more")).toBeNull();
    expect(deviceForToken(tokens, "")).toBeNull();
  });
});

describe("/v1 guard", () => {
  it("401s without a token", async () => {
    expect((await get("/v1/whoami")).status).toBe(401);
  });

  it("401s with a wrong token or wrong scheme", async () => {
    expect((await get("/v1/whoami", "Bearer nope")).status).toBe(401);
    expect((await get("/v1/whoami", "Basic tok-phone")).status).toBe(401);
  });

  it("401s everything when no tokens are configured", async () => {
    const open = createApp({ deviceTokens: new Map(), memos });
    const res = await open.handle(
      new Request("http://iris.test/v1/whoami", { headers: { authorization: "Bearer " } }),
    );
    expect(res.status).toBe(401);
  });

  it("passes a valid token and names the device", async () => {
    const res = await get("/v1/whoami", "Bearer tok-phone");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ device: "iphone" });
  });

  it("leaves /health public", async () => {
    const res = await get("/health");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ status: "ok", degraded: [] });
  });

  it("reports degraded subsystems on /health", async () => {
    const degraded = createApp({ deviceTokens: tokens, memos, degraded: ["otel"] });
    const res = await degraded.handle(new Request("http://iris.test/health"));
    expect(await res.json()).toEqual({ status: "degraded", degraded: ["otel"] });
  });
});
