import { describe, expect, it } from "bun:test";
import { seedMemo, testStore } from "../memo/test-support.js";
import type { Summary } from "../memo/memo.js";
import { fixedClock } from "../ports/clock.js";
import { fakeApnsTransport } from "../ports/fakes.js";
import type { ApnsResult } from "../ports/apns.js";
import type { ApnsEnv } from "../ports/devices.js";
import { createApnsNotifier } from "./notifier-apns.js";
import { createSqliteDeviceStore } from "./sqlite-devices.js";

const TOPIC = "com.example.iris";
const summary: Summary = { headline: "Buy milk", detail: "Buy milk tomorrow", spoken: "Buy milk." };
const phone = { device: "iphone", name: "Test iPhone", platform: "ios" as const };

function setup(options: { results?: ApnsResult[]; apnsEnv?: ApnsEnv | null } = {}) {
  const { db, clock, store } = testStore();
  const devices = createSqliteDeviceStore({ db, clock });
  const transport = fakeApnsTransport(options.results ? { results: options.results } : {});
  const lines: { event: string; fields: Record<string, unknown> }[] = [];
  const notifier = createApnsNotifier({
    transport,
    devices,
    topic: TOPIC,
    clock: fixedClock("2026-01-01T12:00:00.000Z"),
    logger: (event, fields) => lines.push({ event, fields: fields ?? {} }),
  });
  const memo = { ...seedMemo(store, "summarized", "iphone"), route: "hermes" };
  devices.registerDevice({
    ...phone,
    apnsEnv: options.apnsEnv === undefined ? "production" : options.apnsEnv,
  });
  return { devices, transport, notifier, memo, lines };
}

const events = (lines: { event: string }[]) => lines.map((l) => l.event);

describe("notify", () => {
  it("succeeds and logs when neither token is registered", async () => {
    const { notifier, memo, transport, lines } = setup();
    await notifier.notify({ memo, summary });
    expect(transport.calls).toEqual([]);
    expect(events(lines)).toEqual(["notify.no_token"]);
  });

  it("sends the Live Activity end and the alert to the device's environment", async () => {
    const { notifier, memo, transport, devices } = setup({ apnsEnv: "production" });
    devices.registerDevice({ ...phone, apnsToken: "aa11" });
    devices.setActivityToken({ memoId: memo.id, token: "bb22" });

    await notifier.notify({ memo, summary });

    expect(
      transport.calls.map((c) => [
        c.deviceToken,
        c.environment,
        c.headers.pushType,
        c.headers.topic,
      ]),
    ).toEqual([
      ["bb22", "production", "liveactivity", `${TOPIC}.push-type.liveactivity`],
      ["aa11", "production", "alert", TOPIC],
    ]);
  });

  it("defaults to the sandbox when the device never reported an environment", async () => {
    const { notifier, memo, transport, devices } = setup({ apnsEnv: null });
    devices.registerDevice({ ...phone, apnsToken: "aa11" });
    await notifier.notify({ memo, summary });
    expect(transport.calls.map((c) => c.environment)).toEqual(["sandbox"]);
  });

  it("sends only the alert without an activity token, and only the end without an apns token", async () => {
    const a = setup();
    a.devices.registerDevice({ ...phone, apnsToken: "aa11" });
    await a.notifier.notify({ memo: a.memo, summary });
    expect(a.transport.calls.map((c) => c.headers.pushType)).toEqual(["alert"]);

    const b = setup();
    b.devices.setActivityToken({ memoId: b.memo.id, token: "bb22" });
    await b.notifier.notify({ memo: b.memo, summary });
    expect(b.transport.calls.map((c) => c.headers.pushType)).toEqual(["liveactivity"]);
  });

  it("logs a rejection and clears a dead alert token without failing", async () => {
    const { notifier, memo, devices, lines } = setup({
      results: [{ ok: false, status: 410, reason: "Unregistered" }],
    });
    devices.registerDevice({ ...phone, apnsToken: "aa11" });

    await notifier.notify({ memo, summary });

    expect(devices.getDevice("iphone")?.apnsToken).toBeNull();
    expect(lines).toEqual([
      {
        event: "notify.apns_rejected",
        fields: {
          memo_id: memo.id,
          device: "iphone",
          kind: "alert",
          status: 410,
          reason: "Unregistered",
        },
      },
    ]);
  });

  it("clears a dead activity token on BadDeviceToken but keeps the alert token", async () => {
    const { notifier, memo, devices } = setup({
      results: [{ ok: false, status: 400, reason: "BadDeviceToken" }],
    });
    devices.registerDevice({ ...phone, apnsToken: "aa11" });
    devices.setActivityToken({ memoId: memo.id, token: "bb22" });

    await notifier.notify({ memo, summary });

    expect(devices.getActivityToken(memo.id)).toBeNull();
    expect(devices.getDevice("iphone")?.apnsToken).toBe("aa11");
  });

  it("does not clear a token that was replaced while the push was in flight", async () => {
    const { notifier, memo, devices, transport } = setup({
      results: [{ ok: false, status: 410, reason: "Unregistered" }],
    });
    devices.registerDevice({ ...phone, apnsToken: "aa11" });
    const send = transport.send;
    transport.send = async (params) => {
      const result = await send(params);
      devices.registerDevice({ ...phone, apnsToken: "fresh" });
      return result;
    };

    await notifier.notify({ memo, summary });

    expect(devices.getDevice("iphone")?.apnsToken).toBe("fresh");
  });

  it("keeps the tokens and succeeds on a non-token 4xx such as a provider auth error", async () => {
    const { notifier, memo, devices, lines } = setup({
      results: [{ ok: false, status: 403, reason: "InvalidProviderToken" }],
    });
    devices.registerDevice({ ...phone, apnsToken: "aa11" });

    await notifier.notify({ memo, summary });

    expect(devices.getDevice("iphone")?.apnsToken).toBe("aa11");
    expect(events(lines)).toEqual(["notify.apns_rejected"]);
  });

  it.each([
    [0, "connection reset"],
    [429, "TooManyRequests"],
    [500, "InternalServerError"],
    [503, "ServiceUnavailable"],
    [403, "ExpiredProviderToken"],
  ])("throws on a transient failure (%d %s) so the step can be retried", async (status, reason) => {
    const { notifier, memo, devices } = setup({ results: [{ ok: false, status, reason }] });
    devices.registerDevice({ ...phone, apnsToken: "aa11" });

    await expect(notifier.notify({ memo, summary })).rejects.toThrow(`apns: ${status} ${reason}`);
    expect(devices.getDevice("iphone")?.apnsToken).toBe("aa11");
  });

  it("still sends the alert when the Live Activity end failed transiently, then throws", async () => {
    const { notifier, memo, devices, transport } = setup({
      results: [{ ok: false, status: 503, reason: "ServiceUnavailable" }],
    });
    devices.registerDevice({ ...phone, apnsToken: "aa11" });
    devices.setActivityToken({ memoId: memo.id, token: "bb22" });

    await expect(notifier.notify({ memo, summary })).rejects.toThrow("503");
    expect(transport.calls).toHaveLength(2);
  });
});

describe("phase", () => {
  it("does nothing without an activity token", async () => {
    const { notifier, memo, transport } = setup();
    await notifier.phase({ memo });
    expect(transport.calls).toEqual([]);
  });

  it("sends a priority 5 update with the current content state", async () => {
    const { notifier, memo, transport, devices } = setup();
    devices.setActivityToken({ memoId: memo.id, token: "bb22" });
    await notifier.phase({ memo });
    expect(transport.calls).toHaveLength(1);
    expect(transport.calls[0]).toMatchObject({
      deviceToken: "bb22",
      headers: { priority: 5, pushType: "liveactivity" },
      payload: { aps: { event: "update", "content-state": { phase: "processing" } } },
    });
  });

  it("never throws: a transient failure is logged, a dead token cleared, a thrown send swallowed", async () => {
    const { notifier, memo, transport, devices, lines } = setup({
      results: [
        { ok: false, status: 503, reason: "ServiceUnavailable" },
        { ok: false, status: 410, reason: "Unregistered" },
      ],
    });
    devices.setActivityToken({ memoId: memo.id, token: "bb22" });

    await notifier.phase({ memo });
    expect(devices.getActivityToken(memo.id)).toBe("bb22");
    await notifier.phase({ memo });
    expect(devices.getActivityToken(memo.id)).toBeNull();

    transport.send = async () => {
      throw new Error("boom");
    };
    devices.setActivityToken({ memoId: memo.id, token: "cc33" });
    await notifier.phase({ memo });

    expect(events(lines)).toEqual([
      "notify.apns_transient",
      "notify.apns_rejected",
      "notify.phase_failed",
    ]);
  });
});
