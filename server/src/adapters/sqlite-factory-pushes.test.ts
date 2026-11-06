import { describe, expect, it } from "bun:test";
import { testStore } from "../memo/test-support.js";
import { createSqliteFactoryPushStore } from "./sqlite-factory-pushes.js";

const setup = () => {
  const { db, clock } = testStore();
  return { db, clock, pushes: createSqliteFactoryPushStore({ db, clock }) };
};

describe("factory push store", () => {
  it("claims a new ask once it is marked, and again while it is not", () => {
    const { pushes } = setup();
    expect(pushes.claim("a", { silent: false })).toBe(true);
    // Seen but never announced (a failed try): still owed.
    expect(pushes.claim("a", { silent: false })).toBe(true);
    pushes.markPushed("a");
    expect(pushes.claim("a", { silent: false })).toBe(false);
  });

  it("records a silent ask as announced without owing a push", () => {
    const { pushes } = setup();
    expect(pushes.claim("a", { silent: true })).toBe(false);
    expect(pushes.claim("a", { silent: false })).toBe(false);
  });

  it("reports the baseline until it is completed, across a restart", () => {
    const { db, clock, pushes } = setup();
    expect(pushes.startBaseline()).toBe(true);
    // A restart before the scan finished: still the first scan.
    expect(createSqliteFactoryPushStore({ db, clock }).startBaseline()).toBe(true);
    pushes.completeBaseline();
    expect(createSqliteFactoryPushStore({ db, clock }).startBaseline()).toBe(false);
  });
});
