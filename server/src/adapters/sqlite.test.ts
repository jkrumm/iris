import { Database } from "bun:sqlite";
import { describe, expect, it } from "bun:test";
import { MemoError } from "../memo/errors.js";
import { seedMemo, testStore } from "../memo/test-support.js";
import { createSqliteMemoStore, migrate } from "./sqlite.js";
import { MIGRATIONS } from "./sqlite-migrations.js";

const input = (id: string) => ({
  id,
  mode: "journal" as const,
  device: "iphone",
  startedAt: "2026-01-01T00:00:00.000Z",
});

describe("createMemo", () => {
  it("is idempotent and keeps the first row", () => {
    const { store, clock } = testStore();
    const id = crypto.randomUUID();
    const first = store.createMemo(input(id));
    clock.advance(1000);
    const second = store.createMemo({ ...input(id), mode: "hermes" });
    expect(first.created).toBe(true);
    expect(second.created).toBe(false);
    expect(second.memo).toEqual(first.memo);
    expect(first.memo).toMatchObject({ state: "receiving", mode: "journal", segmentCount: null });
  });

  it("stamps timestamps from the injected clock", () => {
    const { store, clock } = testStore();
    const memo = seedMemo(store);
    expect(memo.createdAt).toBe("2026-01-01T00:00:00.000Z");
    clock.advance(5000);
    store.markReceived({ id: memo.id, segmentCount: 2 });
    expect(store.getMemo(memo.id)?.updatedAt).toBe("2026-01-01T00:00:05.000Z");
  });

  it("returns null for an unknown memo", () => {
    expect(testStore().store.getMemo("nope")).toBeNull();
  });
});

describe("listMemos", () => {
  it("pages newest-first and the cursor stays stable while new memos arrive", () => {
    const { store } = testStore();
    const newest = Array.from({ length: 5 }, () => seedMemo(store).id).toReversed();
    const page1 = store.listMemos({ limit: 2 });
    expect(page1.memos.map((m) => m.id)).toEqual(newest.slice(0, 2));
    expect(page1.nextCursor).not.toBeNull();

    seedMemo(store);
    const page2 = store.listMemos({ limit: 2, cursor: page1.nextCursor });
    expect(page2.memos.map((m) => m.id)).toEqual(newest.slice(2, 4));
    const page3 = store.listMemos({ limit: 2, cursor: page2.nextCursor });
    expect(page3.memos.map((m) => m.id)).toEqual(newest.slice(4));
    expect(page3.nextCursor).toBeNull();
  });

  it("reports no cursor when the page is exactly full and last", () => {
    const { store } = testStore();
    seedMemo(store);
    seedMemo(store);
    expect(store.listMemos({ limit: 2 }).nextCursor).toBeNull();
  });

  it("rejects a malformed cursor", () => {
    const { store } = testStore();
    expect(() => store.listMemos({ limit: 2, cursor: "abc" })).toThrow(MemoError);
  });
});

describe("segments", () => {
  it("records first-write-wins, lists indices in order, and deletes them", () => {
    const { store } = testStore();
    const { id } = seedMemo(store);
    expect(store.recordSegment({ id, index: 2, bytes: 10, sha256: "aa" })).toBe(true);
    expect(store.recordSegment({ id, index: 0, bytes: 10, sha256: "bb" })).toBe(true);
    expect(store.recordSegment({ id, index: 2, bytes: 99, sha256: "cc" })).toBe(false);
    expect(store.getSegment({ id, index: 2 })).toEqual({ bytes: 10, sha256: "aa" });
    expect(store.getSegment({ id, index: 5 })).toBeNull();
    expect(store.listSegmentIndices(id)).toEqual([0, 2]);
    store.deleteSegments(id);
    expect(store.listSegmentIndices(id)).toEqual([]);
  });
});

describe("state changes", () => {
  it("markReceived only applies to a receiving memo", () => {
    const { store } = testStore();
    const { id } = seedMemo(store);
    expect(store.markReceived({ id, segmentCount: 3 })).toBe(true);
    expect(store.markReceived({ id, segmentCount: 4 })).toBe(false);
    expect(store.getMemo(id)).toMatchObject({ state: "received", segmentCount: 3 });
  });

  it("transition is a compare-and-set", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "received");
    expect(store.transition({ id, from: "transcribed", to: "routed" })).toBe(false);
    expect(store.transition({ id, from: "received", to: "transcribed" })).toBe(true);
    expect(store.transition({ id, from: "received", to: "transcribed" })).toBe(false);
    expect(store.getMemo(id)?.state).toBe("transcribed");
  });

  it("listNonTerminal skips receiving, notified, failed and needs_route", () => {
    const { store } = testStore();
    seedMemo(store, "receiving");
    seedMemo(store, "notified");
    const failed = seedMemo(store, "transcribed");
    store.markStepStarted({ id: failed.id, step: "route" });
    store.markStepFailed({ id: failed.id, step: "route", error: "x" });
    const parked = seedMemo(store, "transcribed");
    store.transition({ id: parked.id, from: "transcribed", to: "needs_route" });
    const mid = seedMemo(store, "acted");
    const fresh = seedMemo(store, "received");
    expect(
      store
        .listNonTerminal()
        .map((m) => m.id)
        .toSorted(),
    ).toEqual([mid.id, fresh.id].toSorted());
  });
});

describe("step records", () => {
  it("tracks a step from running to done with usage and cost", () => {
    const { store, clock } = testStore();
    const { id } = seedMemo(store, "received");
    store.markStepStarted({ id, step: "transcribe" });
    expect(store.listStepRecords(id)[0]).toMatchObject({ status: "running", finishedAt: null });
    clock.advance(2000);
    store.markStepDone({ id, step: "transcribe", usage: { tokens: 5 }, costUsd: 0.01 });
    expect(store.listStepRecords(id)).toEqual([
      {
        step: "transcribe",
        status: "done",
        startedAt: "2026-01-01T00:00:00.000Z",
        finishedAt: "2026-01-01T00:00:02.000Z",
        error: null,
        usage: { tokens: 5 },
        costUsd: 0.01,
      },
    ]);
  });

  it("replaces the row when a step runs again and lists in pipeline order", () => {
    const { store, clock } = testStore();
    const { id } = seedMemo(store, "received");
    store.markStepStarted({ id, step: "route" });
    store.markStepStarted({ id, step: "transcribe" });
    store.markStepFailed({ id, step: "transcribe", error: "first" });
    clock.advance(1000);
    store.markStepStarted({ id, step: "transcribe" });
    const records = store.listStepRecords(id);
    expect(records.map((r) => r.step)).toEqual(["transcribe", "route"]);
    expect(records[0]).toMatchObject({
      status: "running",
      error: null,
      startedAt: "2026-01-01T00:00:01.000Z",
    });
  });

  it("markStepFailed fails the memo and records where and why", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "transcribed");
    store.markStepStarted({ id, step: "route" });
    store.markStepFailed({ id, step: "route", error: "no route" });
    expect(store.getMemo(id)).toMatchObject({
      state: "failed",
      failedStep: "route",
      error: "no route",
    });
    expect(store.listStepRecords(id)[0]).toMatchObject({ status: "failed", error: "no route" });
  });

  it("resetForRetry rewinds a failed memo and clears the timeline from that step on", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "received");
    store.markStepStarted({ id, step: "transcribe" });
    store.markStepDone({ id, step: "transcribe" });
    store.transition({ id, from: "received", to: "transcribed" });
    store.markStepStarted({ id, step: "route" });
    store.markStepFailed({ id, step: "route", error: "x" });

    expect(store.resetForRetry({ id, from: "route" })).toBe(true);
    expect(store.getMemo(id)).toMatchObject({
      state: "transcribed",
      failedStep: null,
      error: null,
    });
    expect(store.listStepRecords(id).map((r) => r.step)).toEqual(["transcribe"]);
    expect(store.resetForRetry({ id, from: "route" })).toBe(false);
  });
});

describe("migrations", () => {
  it("are idempotent on an existing database and keep its data", () => {
    const db = new Database(":memory:");
    const clock = testStore().clock;
    const first = createSqliteMemoStore({ db, clock });
    const { id } = first.createMemo(input(crypto.randomUUID())).memo;
    expect(db.query<{ user_version: number }, []>("PRAGMA user_version").get()?.user_version).toBe(
      MIGRATIONS.length,
    );

    migrate(db);
    const second = createSqliteMemoStore({ db, clock });
    expect(second.getMemo(id)?.id).toBe(id);
    expect(db.query<{ user_version: number }, []>("PRAGMA user_version").get()?.user_version).toBe(
      MIGRATIONS.length,
    );
  });

  it("upgrades a version-1 database, keeping its segments with an empty sha256", () => {
    const db = new Database(":memory:");
    migrate(db, MIGRATIONS.slice(0, 1));
    const id = crypto.randomUUID();
    db.query(
      "INSERT INTO memos (id, mode, device, started_at, state, created_at, updated_at) VALUES (?, 'auto', 'iphone', 't', 'receiving', 't', 't')",
    ).run(id);
    db.query("INSERT INTO segments (memo_id, idx, bytes) VALUES (?, 0, 5)").run(id);

    const store = createSqliteMemoStore({ db, clock: testStore().clock });
    expect(store.getSegment({ id, index: 0 })).toEqual({ bytes: 5, sha256: "" });
    expect(store.recordSegment({ id, index: 1, bytes: 5, sha256: "ab" })).toBe(true);
    expect(store.listSegmentIndices(id)).toEqual([0, 1]);
  });

  it("applies only the migrations beyond the stored version", () => {
    const db = new Database(":memory:");
    migrate(db, ["CREATE TABLE a (x INTEGER);"]);
    migrate(db, ["CREATE TABLE a (x INTEGER);", "CREATE TABLE b (y INTEGER);"]);
    const tables = db
      .query<{ name: string }, []>(
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
      )
      .all()
      .map((r) => r.name);
    expect(tables).toEqual(["a", "b"]);
  });

  it("rolls a failing migration back without bumping the version", () => {
    const db = new Database(":memory:");
    expect(() => migrate(db, ["CREATE TABLE a (x INTEGER); BOGUS SQL;"])).toThrow();
    expect(db.query<{ user_version: number }, []>("PRAGMA user_version").get()?.user_version).toBe(
      0,
    );
    expect(db.query("SELECT name FROM sqlite_master WHERE name = 'a'").get()).toBeNull();
  });
});
