import { describe, expect, it } from "bun:test";
import { testStore } from "../memo/test-support.js";
import { fakeApnsTransport } from "../ports/fakes.js";
import { createApnsFactoryAlerter } from "./factory-alerter.js";
import { createSqliteDeviceStore } from "./sqlite-devices.js";

const ask = {
  id: "decision:113:1:ask:u1",
  issue: 113,
  short: "Which cache layer?",
  summary: "Keep Redis or not.",
};
const quiet = () => {};

function setup(results: Parameters<typeof fakeApnsTransport>[0] = {}) {
  const { db, clock } = testStore();
  const devices = createSqliteDeviceStore({ db, clock });
  const transport = fakeApnsTransport(results);
  const alerter = createApnsFactoryAlerter({
    transport,
    devices,
    topic: "com.example.iris",
    logger: quiet,
  });
  const phone = { device: "iphone", name: "P", platform: "ios" as const };
  return { devices, transport, alerter, phone };
}

describe("apns factory alerter", () => {
  it("sends to every device with a token, in its registered environment", async () => {
    const { devices, transport, alerter, phone } = setup();
    devices.registerDevice({ ...phone, apnsToken: "aa11", apnsEnv: "production" });
    devices.registerDevice({ device: "mac", name: "M", platform: "macos", apnsToken: "bb22" });
    devices.registerDevice({ device: "ipad", name: "I", platform: "ios" });
    expect(await alerter.alert(ask)).toBe("sent");
    expect(transport.calls.map((c) => [c.deviceToken, c.environment])).toEqual([
      ["aa11", "production"],
      ["bb22", "sandbox"],
    ]);
    expect(transport.calls[0]?.payload).toMatchObject({ factory: { askId: ask.id, issue: 113 } });
  });

  it("reports no_token without a registered token", async () => {
    const { alerter, devices, phone, transport } = setup();
    devices.registerDevice(phone);
    expect(await alerter.alert(ask)).toBe("no_token");
    expect(transport.calls).toEqual([]);
  });

  it("retries only when nothing was delivered and a failure was transient", async () => {
    const transient = setup({
      results: [{ ok: false, status: 503, reason: "ServiceUnavailable" }],
    });
    transient.devices.registerDevice({
      ...transient.phone,
      apnsToken: "aa11",
      apnsEnv: "production",
    });
    expect(await transient.alerter.alert(ask)).toBe("retry");

    const partial = setup({ results: [{ ok: false, status: 503, reason: "x" }, { ok: true }] });
    partial.devices.registerDevice({ ...partial.phone, apnsToken: "aa11" });
    partial.devices.registerDevice({
      device: "mac",
      name: "M",
      platform: "macos",
      apnsToken: "bb22",
    });
    expect(await partial.alerter.alert(ask)).toBe("sent");
  });

  it("clears a dead token and keeps one that may be a sandbox guess", async () => {
    const dead = setup({ results: [{ ok: false, status: 410, reason: "Unregistered" }] });
    dead.devices.registerDevice({ ...dead.phone, apnsToken: "aa11", apnsEnv: "production" });
    expect(await dead.alerter.alert(ask)).toBe("rejected");
    expect(dead.devices.getDevice("iphone")?.apnsToken).toBeNull();

    const guess = setup({ results: [{ ok: false, status: 400, reason: "BadDeviceToken" }] });
    guess.devices.registerDevice({ ...guess.phone, apnsToken: "aa11" });
    expect(await guess.alerter.alert(ask)).toBe("rejected");
    expect(guess.devices.getDevice("iphone")?.apnsToken).toBe("aa11");
  });
});
