import { Database } from "bun:sqlite";
import { describe, expect, it } from "bun:test";
import { MemoError } from "../memo/errors.js";
import type { MemoPatch, MemoState, Step } from "../memo/memo.js";
import { captureLogs, parkMemo, seedMemo, testStore } from "../memo/test-support.js";
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

describe("completeStep", () => {
  const summary = { headline: "h", detail: "d", spoken: "s" };

  it("moves the state, marks the step done and applies the patch in one go", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "received");
    expect(store.getMemo(id)).toMatchObject({
      audioSeconds: null,
      transcript: null,
      summary: null,
    });
    store.markStepStarted({ id, step: "transcribe" });
    const won = store.completeStep({
      id,
      step: "transcribe",
      from: "received",
      to: "transcribed",
      usage: { audioSeconds: 3 },
      costUsd: 0.5,
      patch: { transcript: "hi", audioSeconds: 3 },
    });
    expect(won).toBe(true);
    expect(store.getMemo(id)).toMatchObject({
      state: "transcribed",
      transcript: "hi",
      audioSeconds: 3,
      route: null,
    });
    expect(store.listStepRecords(id)[0]).toMatchObject({
      status: "done",
      usage: { audioSeconds: 3 },
      costUsd: 0.5,
    });
  });

  it("round-trips the summary as JSON", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "acted");
    store.markStepStarted({ id, step: "summarize" });
    store.completeStep({
      id,
      step: "summarize",
      from: "acted",
      to: "summarized",
      patch: { summary },
    });
    expect(store.getMemo(id)?.summary).toEqual(summary);
  });

  it("stores a null summary as SQL NULL, not the text 'null'", () => {
    const { store, db } = testStore();
    const { id } = seedMemo(store, "acted");
    store.markStepStarted({ id, step: "summarize" });
    store.completeStep({
      id,
      step: "summarize",
      from: "acted",
      to: "summarized",
      patch: { summary: null },
    });
    const row = db
      .query<{ summary_json: string | null }, [string]>(
        "SELECT summary_json FROM memos WHERE id = ?",
      )
      .get(id);
    expect(row?.summary_json).toBeNull();
    expect(store.getMemo(id)?.summary).toBeNull();
  });

  it("reads an invalid stored summary as null and logs a warning", async () => {
    const { store, db } = testStore();
    const { id } = seedMemo(store, "summarized");
    db.query("UPDATE memos SET summary_json = ? WHERE id = ?").run('{"headline":1}', id);
    const { result, lines } = await captureLogs(async () => store.getMemo(id));
    expect(result?.summary).toBeNull();
    expect(lines).toContainEqual(
      expect.objectContaining({ event: "memo.summary_invalid", memo_id: id }),
    );

    db.query("UPDATE memos SET summary_json = ? WHERE id = ?").run("not json", id);
    const second = await captureLogs(async () => store.getMemo(id));
    expect(second.result?.summary).toBeNull();
    expect(second.lines).toHaveLength(1);
  });

  it("writes nothing when the compare-and-set loses", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "received");
    store.markStepStarted({ id, step: "transcribe" });
    const won = store.completeStep({
      id,
      step: "transcribe",
      from: "routed",
      to: "acted",
      usage: { x: 1 },
      patch: { transcript: "nope" },
    });
    expect(won).toBe(false);
    expect(store.getMemo(id)).toMatchObject({ state: "received", transcript: null });
    expect(store.listStepRecords(id)[0]).toMatchObject({ status: "running", usage: null });
  });

  it("resetForRetry clears the data columns of the re-run steps and later, keeping earlier ones", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "received");
    const complete = (step: Step, from: MemoState, to: MemoState, patch: MemoPatch) => {
      store.markStepStarted({ id, step });
      store.completeStep({ id, step, from, to, patch });
    };
    complete("transcribe", "received", "transcribed", { transcript: "t", audioSeconds: 2 });
    complete("route", "transcribed", "routed", { route: "hermes" });
    complete("act", "routed", "acted", { destinationRef: "r", replyText: "x" });
    store.markStepStarted({ id, step: "summarize" });
    store.markStepFailed({ id, step: "summarize", error: "boom" });

    store.resetForRetry({ id, from: "act" });
    expect(store.getMemo(id)).toMatchObject({
      state: "routed",
      transcript: "t",
      audioSeconds: 2,
      route: "hermes",
      destinationRef: null,
      replyText: null,
      summary: null,
    });
  });
});

describe("route decisions", () => {
  const decision = {
    source: "decide" as const,
    destination: "journal",
    tab: null,
    confidence: 0.91,
    model: "decider-1",
    costUsd: 0.0004,
    reason: null,
    outcome: "routed" as const,
  };

  it("appends the decision row in the same transaction as the step completion", () => {
    const { store, clock } = testStore();
    const { id } = seedMemo(store, "transcribed");
    store.markStepStarted({ id, step: "route" });
    clock.advance(1000);
    const won = store.completeStep({
      id,
      step: "route",
      from: "transcribed",
      to: "routed",
      patch: { route: "journal", routeDecision: decision },
    });
    expect(won).toBe(true);
    expect(store.getMemo(id)).toMatchObject({ state: "routed", route: "journal" });
    expect(store.listRouteDecisions(id)).toEqual([
      { ...decision, id: 1, memoId: id, createdAt: clock.now().toISOString() },
    ]);
  });

  it("stores a park with its reason and nullable fields", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "transcribed");
    store.markStepStarted({ id, step: "route" });
    store.completeStep({
      id,
      step: "route",
      from: "transcribed",
      to: "needs_route",
      patch: {
        routeDecision: {
          source: "mode",
          destination: null,
          tab: null,
          confidence: null,
          model: null,
          costUsd: null,
          reason: "journal not available",
          outcome: "needs_route",
        },
      },
    });
    expect(store.getMemo(id)?.route).toBeNull();
    expect(store.listRouteDecisions(id)).toMatchObject([
      {
        destination: null,
        confidence: null,
        reason: "journal not available",
        outcome: "needs_route",
      },
    ]);
  });

  it("writes no row when the compare-and-set loses", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "received");
    store.markStepStarted({ id, step: "route" });
    const won = store.completeStep({
      id,
      step: "route",
      from: "transcribed",
      to: "routed",
      patch: { route: "journal", routeDecision: decision },
    });
    expect(won).toBe(false);
    expect(store.listRouteDecisions(id)).toEqual([]);
  });

  it("keeps the log across a retry and returns rows oldest first", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "transcribed");
    const complete = (to: "routed" | "needs_route", reason: string | null) => {
      store.markStepStarted({ id, step: "route" });
      store.completeStep({
        id,
        step: "route",
        from: "transcribed",
        to,
        patch: { routeDecision: { ...decision, outcome: to, reason } },
      });
    };
    complete("needs_route", "low confidence (0.60)");
    store.transition({ id, from: "needs_route", to: "transcribed" });
    complete("routed", null);
    expect(store.listRouteDecisions(id).map((d) => [d.id, d.reason])).toEqual([
      [1, "low confidence (0.60)"],
      [2, null],
    ]);
  });

  it("rejects an unknown source or outcome and cascades with the memo", () => {
    const { store, db } = testStore();
    const { id } = seedMemo(store, "transcribed");
    const insert = (source: string, outcome: string) =>
      db
        .query(
          "INSERT INTO route_decisions (memo_id, created_at, source, outcome) VALUES (?, 't', ?, ?)",
        )
        .run(id, source, outcome);
    expect(() => insert("guess", "routed")).toThrow();
    expect(() => insert("answer", "maybe")).toThrow();
    insert("correction", "routed");
    db.query("DELETE FROM memos WHERE id = ?").run(id);
    expect(store.listRouteDecisions(id)).toEqual([]);
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

  it("adds route_decisions on top of an existing version-4 database", () => {
    const db = new Database(":memory:");
    migrate(db, MIGRATIONS.slice(0, 4));
    const id = crypto.randomUUID();
    db.query(
      "INSERT INTO memos (id, mode, device, started_at, state, created_at, updated_at) VALUES (?, 'auto', 'iphone', 't', 'transcribed', 't', 't')",
    ).run(id);

    const store = createSqliteMemoStore({ db, clock: testStore().clock });
    expect(store.listRouteDecisions(id)).toEqual([]);
    expect(store.getMemo(id)?.state).toBe("transcribed");
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

describe("answering and correcting a route", () => {
  const answer = {
    source: "answer" as const,
    destination: "hermes" as const,
    tab: null,
    confidence: null,
    model: null,
    costUsd: null,
    reason: null,
    outcome: "routed" as const,
  };

  it("exposes the park reason and suggestion only while the memo is needs_route", () => {
    const { store } = testStore();
    const id = parkMemo(store, { reason: "low confidence (0.60)", destination: "journal" });
    expect(store.getMemo(id)).toMatchObject({
      routeReason: "low confidence (0.60)",
      routeSuggestion: "journal",
    });
    expect(store.listMemos({ limit: 5 }).memos[0]).toMatchObject({
      routeReason: "low confidence (0.60)",
    });

    const plain = parkMemo(store, { reason: "journal not available" });
    const memo = store.getMemo(plain);
    expect(memo?.routeReason).toBe("journal not available");
    expect(memo).not.toHaveProperty("routeSuggestion");

    store.answerRoute({ id, decision: answer });
    const answered = store.getMemo(id);
    expect(answered).not.toHaveProperty("routeReason");
    expect(answered).not.toHaveProperty("routeSuggestion");
  });

  it("answerRoute moves needs_route to routed, sets the route and logs in one step", () => {
    const { store } = testStore();
    const id = parkMemo(store, { reason: "decide refused" });
    expect(store.answerRoute({ id, decision: answer })).toBe(true);
    expect(store.getMemo(id)).toMatchObject({ state: "routed", route: "hermes" });
    expect(store.listRouteDecisions(id).map((d) => [d.source, d.outcome])).toEqual([
      ["decide", "needs_route"],
      ["answer", "routed"],
    ]);
  });

  it("answerRoute writes nothing unless the memo is needs_route", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "transcribed");
    expect(store.answerRoute({ id, decision: answer })).toBe(false);
    const parked = parkMemo(store, { reason: "decide refused" });
    expect(store.answerRoute({ id: parked, decision: answer })).toBe(true);
    expect(store.answerRoute({ id: parked, decision: answer })).toBe(false);
    expect(store.listRouteDecisions(id)).toEqual([]);
    expect(store.listRouteDecisions(parked).filter((d) => d.source === "answer")).toHaveLength(1);
  });

  it("recordCorrection logs without touching the memo, only from acted onwards", () => {
    const { store } = testStore();
    const correction = { ...answer, source: "correction" as const };
    for (const state of ["transcribed", "routed"] as const) {
      const { id } = seedMemo(store, state);
      expect(store.recordCorrection({ id, decision: correction })).toBe(false);
      expect(store.listRouteDecisions(id)).toEqual([]);
    }
    for (const state of ["acted", "summarized", "notified"] as const) {
      const { id } = seedMemo(store, state);
      const before = store.getMemo(id);
      expect(store.recordCorrection({ id, decision: correction })).toBe(true);
      expect(store.getMemo(id)).toEqual(before);
      expect(store.listRouteDecisions(id)).toMatchObject([{ source: "correction" }]);
    }
    expect(store.recordCorrection({ id: crypto.randomUUID(), decision: correction })).toBe(false);
  });
});
