import { describe, expect, it } from "bun:test";
import { seedMemo, testStore } from "../memo/test-support.js";
import { createSqliteDeviceStore } from "./sqlite-devices.js";

function setup() {
  const { db, clock, store } = testStore();
  return { db, clock, store, devices: createSqliteDeviceStore({ db, clock }) };
}

const phone = { device: "iphone", name: "Test iPhone", platform: "ios" as const };

describe("clearApnsToken", () => {
  it("clears the expected token and reports it", () => {
    const { devices } = setup();
    devices.registerDevice({ ...phone, apnsToken: "aa11", pushToStartToken: "bb22" });
    expect(devices.clearApnsToken({ device: "iphone", expected: "aa11" })).toBe(true);
    expect(devices.getDevice("iphone")).toMatchObject({
      apnsToken: null,
      pushToStartToken: "bb22",
    });
  });

  it("does not clear a token that rotated meanwhile", () => {
    const { devices } = setup();
    devices.registerDevice({ ...phone, apnsToken: "aa11" });
    devices.registerDevice({ ...phone, apnsToken: "fresh" });
    expect(devices.clearApnsToken({ device: "iphone", expected: "aa11" })).toBe(false);
    expect(devices.getDevice("iphone")?.apnsToken).toBe("fresh");
  });

  it("leaves lastSeenAt and updatedAt untouched", () => {
    const { devices, clock } = setup();
    const before = devices.registerDevice({ ...phone, apnsToken: "aa11" });
    clock.advance(60_000);
    expect(devices.clearApnsToken({ device: "iphone", expected: "aa11" })).toBe(true);
    const after = devices.getDevice("iphone");
    expect(after?.lastSeenAt).toBe(before.lastSeenAt);
    expect(after?.updatedAt).toBe(before.updatedAt);
  });

  it("is false for an unknown device or one without a token", () => {
    const { devices } = setup();
    expect(devices.clearApnsToken({ device: "ghost", expected: "aa11" })).toBe(false);
    devices.registerDevice(phone);
    expect(devices.clearApnsToken({ device: "iphone", expected: "aa11" })).toBe(false);
  });
});

describe("registerDevice", () => {
  it("inserts a device with its tokens and stamps it from the clock", () => {
    const { devices } = setup();
    const registered = devices.registerDevice({
      ...phone,
      apnsToken: "aa11",
      apnsEnv: "sandbox",
      pushToStartToken: "bb22",
    });
    expect(registered).toEqual({
      ...phone,
      apnsToken: "aa11",
      apnsEnv: "sandbox",
      pushToStartToken: "bb22",
      lastSeenAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:00.000Z",
    });
    expect(devices.getDevice("iphone")).toEqual(registered);
  });

  it("stores null tokens when none were sent", () => {
    const { devices } = setup();
    expect(devices.registerDevice(phone)).toMatchObject({
      apnsToken: null,
      apnsEnv: null,
      pushToStartToken: null,
    });
  });

  it("upserts by device and keeps stored tokens when they are omitted or empty", () => {
    const { devices, clock } = setup();
    devices.registerDevice({
      ...phone,
      apnsToken: "aa11",
      apnsEnv: "production",
      pushToStartToken: "bb22",
    });
    clock.advance(60_000);
    const again = devices.registerDevice({
      device: "iphone",
      name: "Renamed",
      platform: "ios",
      apnsToken: "",
      pushToStartToken: undefined,
    });
    expect(again).toMatchObject({
      name: "Renamed",
      apnsToken: "aa11",
      apnsEnv: "production",
      pushToStartToken: "bb22",
      lastSeenAt: "2026-01-01T00:01:00.000Z",
    });
    expect(devices.listDevices()).toHaveLength(1);
  });

  it("replaces a token that is sent and clears one that is explicitly null", () => {
    const { devices } = setup();
    devices.registerDevice({ ...phone, apnsToken: "aa11", pushToStartToken: "bb22" });
    const next = devices.registerDevice({ ...phone, apnsToken: "cc33", pushToStartToken: null });
    expect(next).toMatchObject({ apnsToken: "cc33", pushToStartToken: null });
  });

  it("keeps devices apart and lists them oldest first", () => {
    const { devices } = setup();
    devices.registerDevice(phone);
    devices.registerDevice({ device: "macbook", name: "MacBook", platform: "macos" });
    devices.registerDevice({ ...phone, name: "again" });
    expect(devices.listDevices().map((d) => d.device)).toEqual(["iphone", "macbook"]);
    expect(devices.getDevice("nope")).toBeNull();
  });
});

describe("activity tokens", () => {
  it("stores and replaces the token of a memo", () => {
    const { devices, store } = setup();
    const { id } = seedMemo(store);
    expect(devices.getActivityToken(id)).toBeNull();
    expect(devices.setActivityToken({ memoId: id, token: "aa" })).toBe(true);
    expect(devices.setActivityToken({ memoId: id, token: "bb" })).toBe(true);
    expect(devices.getActivityToken(id)).toBe("bb");
  });

  it("clears the token and tolerates a second clear", () => {
    const { devices, store } = setup();
    const { id } = seedMemo(store);
    devices.setActivityToken({ memoId: id, token: "aa" });
    devices.clearActivityToken(id);
    devices.clearActivityToken(id);
    expect(devices.getActivityToken(id)).toBeNull();
  });

  it("refuses an unknown memo", () => {
    const { devices } = setup();
    expect(devices.setActivityToken({ memoId: crypto.randomUUID(), token: "aa" })).toBe(false);
  });

  it("is dropped with its memo", () => {
    const { devices, store, db } = setup();
    const { id } = seedMemo(store);
    devices.setActivityToken({ memoId: id, token: "aa" });
    db.query("DELETE FROM memos WHERE id = ?").run(id);
    expect(devices.getActivityToken(id)).toBeNull();
    expect(db.query("SELECT 1 FROM activity_tokens").get()).toBeNull();
  });
});
