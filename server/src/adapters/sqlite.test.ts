import { Database } from "bun:sqlite";
import { describe, expect, it } from "bun:test";
import { MemoError } from "../memo/errors.js";
import type { MemoPatch, MemoState, ReplyAsset, Step } from "../memo/memo.js";
import { captureLogs, legacyParkedMemo, seedMemo, testStore } from "../memo/test-support.js";
import { createSqliteMemoStore, migrate } from "./sqlite.js";
import { MIGRATIONS } from "./sqlite-migrations.js";

const input = (id: string) => ({
  id,
  mode: "journal" as const,
  device: "iphone",
  startedAt: "2026-01-01T00:00:00.000Z",
});

describe("createTextMemo", () => {
  it("creates in transcribed with the transcript, idempotently, without segments", () => {
    const { store } = testStore();
    const id = crypto.randomUUID();
    const first = store.createTextMemo({ ...input(id), text: "kauf Milch" });
    const second = store.createTextMemo({ ...input(id), text: "anderer Text" });
    expect(first.created).toBe(true);
    expect(first.memo).toMatchObject({
      state: "transcribed",
      transcript: "kauf Milch",
      segmentCount: null,
      audioSeconds: null,
    });
    expect(second.created).toBe(false);
    expect(second.memo).toEqual(first.memo);
    expect(store.listSegmentIndices(id)).toEqual([]);
    expect(store.listStepRecords(id)).toEqual([]);
  });
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

describe("listMemos search and filters", () => {
  /** A memo in `state` carrying `patch`, written the way a step would (same-state completion). */
  const memoWith = (
    store: ReturnType<typeof testStore>["store"],
    state: MemoState,
    patch: MemoPatch,
  ) => {
    const { id } = seedMemo(store, state);
    store.completeStep({ id, step: "transcribe", from: state, to: state, patch });
    return id;
  };
  const summary = (headline: string) => ({ headline, detail: "d", spoken: "s" });
  const ids = (page: { memos: { id: string }[] }) => page.memos.map((m) => m.id);

  it("finds transcript and headline text, ignoring case and umlauts, with prefix terms ANDed", () => {
    const { store } = testStore();
    const kalender = memoWith(store, "notified", {
      transcript: "Trag den Termin in den Kalender ein",
    });
    const uebung = memoWith(store, "notified", {
      transcript: "irgendwas",
      summary: summary("Übung am Donnerstag"),
    });
    memoWith(store, "notified", { transcript: "Milch kaufen" });

    expect(ids(store.listMemos({ limit: 10, q: "kalend" }))).toEqual([kalender]);
    expect(ids(store.listMemos({ limit: 10, q: "KALENDER" }))).toEqual([kalender]);
    expect(ids(store.listMemos({ limit: 10, q: "ubung" }))).toEqual([uebung]);
    expect(ids(store.listMemos({ limit: 10, q: "übung donn" }))).toEqual([uebung]);
    expect(ids(store.listMemos({ limit: 10, q: "übung kalender" }))).toEqual([]);
    expect(ids(store.listMemos({ limit: 10, q: "   " }))).toHaveLength(3);
  });

  it("keeps the index in step with later writes", () => {
    const { store } = testStore();
    const id = memoWith(store, "transcribed", { transcript: "alt" });
    store.completeStep({
      id,
      step: "transcribe",
      from: "transcribed",
      to: "transcribed",
      patch: { transcript: "neu geschrieben" },
    });
    expect(ids(store.listMemos({ limit: 5, q: "alt" }))).toEqual([]);
    expect(ids(store.listMemos({ limit: 5, q: "geschr" }))).toEqual([id]);
  });

  it("never lets user input act as MATCH syntax", () => {
    const { store } = testStore();
    const id = memoWith(store, "notified", { transcript: "foo bar NEAR baz" });
    for (const q of [
      '"',
      'foo"',
      "foo*",
      "foo OR",
      "NOT foo",
      "(foo",
      "foo:bar",
      "^foo",
      "col:x -y",
    ]) {
      expect(() => store.listMemos({ limit: 5, q })).not.toThrow();
    }
    expect(ids(store.listMemos({ limit: 5, q: "near" }))).toEqual([id]);
    expect(ids(store.listMemos({ limit: 5, q: "foo OR zzz" }))).toEqual([]);
    expect(ids(store.listMemos({ limit: 5, q: "foo - bar" }))).toEqual([id]);
    expect(ids(store.listMemos({ limit: 5, q: "... ---" }))).toEqual([]);
  });

  it("filters by kind and state and combines them with q; kind is exact", () => {
    const { store } = testStore();
    const task = memoWith(store, "notified", { transcript: "Milch", kind: "task" });
    const note = memoWith(store, "notified", { transcript: "Milch", kind: "note" });
    const failed = memoWith(store, "acted", { transcript: "Brot", kind: "task" });

    expect(ids(store.listMemos({ limit: 10, kind: "note" }))).toEqual([note]);
    expect(ids(store.listMemos({ limit: 10, state: "acted" }))).toEqual([failed]);
    expect(ids(store.listMemos({ limit: 10, kind: "task", q: "milch" }))).toEqual([task]);
    expect(ids(store.listMemos({ limit: 10, kind: "tas" }))).toEqual([]);
    expect(ids(store.listMemos({ limit: 10, kind: "" }))).toEqual([]);
  });

  it("keeps a memo parked at needs_route (an old row) in the list like any other", () => {
    const { store } = testStore();
    const parked = legacyParkedMemo(store, "Kalender Termin");
    const old = memoWith(store, "notified", { transcript: "Kalender alt" });
    const newest = memoWith(store, "notified", { transcript: "Kalender neu" });

    const page1 = store.listMemos({ limit: 2 });
    expect(ids(page1)).toEqual([newest, old]);
    expect(ids(store.listMemos({ limit: 2, cursor: page1.nextCursor }))).toEqual([parked]);
    expect(ids(store.listMemos({ limit: 10, q: "kalend" }))).toEqual([newest, old, parked]);
    expect(ids(store.listMemos({ limit: 10, state: "needs_route" }))).toEqual([parked]);
  });

  it("backfills the index for memos that existed before the migration", () => {
    const db = new Database(":memory:");
    migrate(db, MIGRATIONS.slice(0, MIGRATIONS.length - 1));
    db.query(
      `INSERT INTO memos (id, mode, device, started_at, state, transcript, summary_json, created_at, updated_at)
       VALUES (?, 'auto', 'iphone', 't', 'notified', 'Der Kalender spinnt', ?, 't', 't')`,
    ).run("old", JSON.stringify({ headline: "Äpfel kaufen", detail: "d", spoken: "s" }));

    const store = createSqliteMemoStore({ db, clock: testStore().clock });
    expect(ids(store.listMemos({ limit: 5, q: "kalend" }))).toHaveLength(1);
    expect(ids(store.listMemos({ limit: 5, q: "apfel" }))).toHaveLength(1);
    const check = db.query("INSERT INTO memo_fts (memo_fts) VALUES ('integrity-check')");
    expect(() => check.run()).not.toThrow();
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
    expect(store.transition({ id, from: "transcribed", to: "acted" })).toBe(false);
    expect(store.transition({ id, from: "received", to: "transcribed" })).toBe(true);
    expect(store.transition({ id, from: "received", to: "transcribed" })).toBe(false);
    expect(store.getMemo(id)?.state).toBe("transcribed");
  });

  it("listNonTerminal skips receiving, notified, failed and needs_route", () => {
    const { store } = testStore();
    seedMemo(store, "receiving");
    seedMemo(store, "notified");
    const failed = seedMemo(store, "transcribed");
    store.markStepStarted({ id: failed.id, step: "act" });
    store.markStepFailed({ id: failed.id, step: "act", error: "x" });
    legacyParkedMemo(store);
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
        attempts: 1,
      },
    ]);
  });

  it("counts a retried try, keeps the last error until the step is done and restarts at 1 on a re-run", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "received");
    store.markStepStarted({ id, step: "transcribe" });
    expect(store.markStepRetrying({ id, step: "transcribe", error: "503" })).toBe(2);
    expect(store.markStepRetrying({ id, step: "transcribe", error: "502" })).toBe(3);
    expect(store.listStepRecords(id)[0]).toMatchObject({
      status: "running",
      attempts: 3,
      error: "502",
    });
    store.markStepDone({ id, step: "transcribe" });
    expect(store.listStepRecords(id)[0]).toMatchObject({ attempts: 3, error: null });
    expect(store.markStepRetrying({ id, step: "transcribe", error: "late" })).toBeNull();
    store.markStepStarted({ id, step: "transcribe" });
    expect(store.listStepRecords(id)[0]?.attempts).toBe(1);
  });

  it("replaces the row when a step runs again and lists in pipeline order", () => {
    const { store, clock } = testStore();
    const { id } = seedMemo(store, "received");
    store.markStepStarted({ id, step: "act" });
    store.markStepStarted({ id, step: "transcribe" });
    store.markStepFailed({ id, step: "transcribe", error: "first" });
    clock.advance(1000);
    store.markStepStarted({ id, step: "transcribe" });
    const records = store.listStepRecords(id);
    expect(records.map((r) => r.step)).toEqual(["transcribe", "act"]);
    expect(records[0]).toMatchObject({
      status: "running",
      error: null,
      startedAt: "2026-01-01T00:00:01.000Z",
    });
  });

  it("markStepFailed fails the memo and records where and why", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "transcribed");
    store.markStepStarted({ id, step: "act" });
    store.markStepFailed({ id, step: "act", error: "hermes down" });
    expect(store.getMemo(id)).toMatchObject({
      state: "failed",
      failedStep: "act",
      error: "hermes down",
    });
    expect(store.listStepRecords(id)[0]).toMatchObject({ status: "failed", error: "hermes down" });
  });

  it("resetForRetry rewinds a failed memo and clears the timeline from that step on", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "received");
    store.markStepStarted({ id, step: "transcribe" });
    store.markStepDone({ id, step: "transcribe" });
    store.transition({ id, from: "received", to: "transcribed" });
    store.markStepStarted({ id, step: "act" });
    store.markStepFailed({ id, step: "act", error: "x" });

    expect(store.resetForRetry({ id, from: "act" })).toBe(true);
    expect(store.getMemo(id)).toMatchObject({
      state: "transcribed",
      failedStep: null,
      error: null,
    });
    expect(store.listStepRecords(id).map((r) => r.step)).toEqual(["transcribe"]);
    expect(store.resetForRetry({ id, from: "act" })).toBe(false);
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
      kind: null,
      actions: [],
    });
    expect(store.listStepRecords(id)[0]).toMatchObject({
      status: "done",
      usage: { audioSeconds: 3 },
      costUsd: 0.5,
    });
  });

  it("round-trips the summary as JSON", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "transcribed");
    store.markStepStarted({ id, step: "act" });
    store.completeStep({ id, step: "act", from: "transcribed", to: "acted", patch: { summary } });
    expect(store.getMemo(id)?.summary).toEqual(summary);
  });

  it("stores a null summary as SQL NULL, not the text 'null'", () => {
    const { store, db } = testStore();
    const { id } = seedMemo(store, "transcribed");
    store.markStepStarted({ id, step: "act" });
    store.completeStep({
      id,
      step: "act",
      from: "transcribed",
      to: "acted",
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

  it("persists kind, actions and summary from the act completion", () => {
    const { store, db } = testStore();
    const { id } = seedMemo(store, "transcribed");
    store.markStepStarted({ id, step: "act" });
    store.completeStep({
      id,
      step: "act",
      from: "transcribed",
      to: "acted",
      patch: { kind: "task", actions: ["web_search", "write_file"], summary },
    });
    expect(store.getMemo(id)).toMatchObject({
      kind: "task",
      actions: ["web_search", "write_file"],
      summary,
    });
    expect(
      db
        .query<{ actions_json: string }, [string]>("SELECT actions_json FROM memos WHERE id = ?")
        .get(id)?.actions_json,
    ).toBe('["web_search","write_file"]');
  });

  it("stores no actions as an empty list and a null kind as NULL", () => {
    const { store, db } = testStore();
    const { id } = seedMemo(store, "transcribed");
    store.markStepStarted({ id, step: "act" });
    store.completeStep({
      id,
      step: "act",
      from: "transcribed",
      to: "acted",
      patch: { kind: null, actions: [] },
    });
    expect(store.getMemo(id)).toMatchObject({ kind: null, actions: [] });
    expect(db.query("SELECT kind, actions_json FROM memos WHERE id = ?").get(id)).toEqual({
      kind: null,
      actions_json: "[]",
    });
  });

  it("reads invalid stored actions as [] and logs memo.actions_invalid", async () => {
    const { store, db } = testStore();
    const { id } = seedMemo(store, "acted");
    db.query("UPDATE memos SET actions_json = ? WHERE id = ?").run('{"a":1}', id);
    const { result, lines } = await captureLogs(async () => store.getMemo(id));
    expect(result?.actions).toEqual([]);
    expect(lines).toContainEqual(
      expect.objectContaining({ event: "memo.actions_invalid", memo_id: id }),
    );

    db.query("UPDATE memos SET actions_json = ? WHERE id = ?").run("not json", id);
    const second = await captureLogs(async () => store.getMemo(id));
    expect(second.result?.actions).toEqual([]);
    expect(second.lines).toContainEqual(
      expect.objectContaining({ event: "memo.actions_invalid", memo_id: id }),
    );
  });

  it("reads NULL actions (before act) as []", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "received");
    expect(store.getMemo(id)?.actions).toEqual([]);
  });

  it("reads an invalid stored summary as null and logs a warning", async () => {
    const { store, db } = testStore();
    const { id } = seedMemo(store, "acted");
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
      from: "acted",
      to: "notified",
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
    complete("act", "transcribed", "acted", {
      destinationRef: "r",
      replyText: "x",
      kind: "task",
      hermesHeadline: "Buy milk",
      actions: ["web_search"],
    });
    complete("summarize", "acted", "summarized", { summary });
    store.markStepStarted({ id, step: "notify" });
    store.markStepFailed({ id, step: "notify", error: "boom" });

    // A retry from notify keeps everything act and summarize produced.
    store.resetForRetry({ id, from: "notify" });
    expect(store.getMemo(id)).toMatchObject({
      state: "summarized",
      kind: "task",
      hermesHeadline: "Buy milk",
      actions: ["web_search"],
      summary,
      replyText: "x",
    });

    store.markStepFailed({ id, step: "act", error: "boom" });
    store.resetForRetry({ id, from: "act" });
    expect(store.getMemo(id)).toMatchObject({
      state: "transcribed",
      transcript: "t",
      audioSeconds: 2,
      route: null,
      destinationRef: null,
      replyText: null,
      summary: null,
      kind: null,
      hermesHeadline: null,
      actions: [],
    });
  });

  it("skipStep moves the memo past a failed optional step, keeping the step row failed", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "acted");
    store.markStepStarted({ id, step: "summarize" });
    expect(store.skipStep({ id, step: "summarize", from: "acted", error: "402" })).toBe(true);
    expect(store.getMemo(id)).toMatchObject({ state: "summarized", failedStep: null, error: null });
    expect(store.listStepRecords(id).find((r) => r.step === "summarize")).toMatchObject({
      status: "failed",
      error: "402",
    });
    // The memo left `acted`: nothing more is written.
    expect(store.skipStep({ id, step: "summarize", from: "acted", error: "again" })).toBe(false);
    expect(() => store.skipStep({ id, step: "act", from: "summarized", error: "x" })).toThrow(
      "not optional",
    );
  });

  it("resetForRetry re-runs a failed summarize on a notified memo, and only then", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "acted");
    store.markStepStarted({ id, step: "summarize" });
    store.skipStep({ id, step: "summarize", from: "acted", error: "402" });
    store.markStepStarted({ id, step: "notify" });
    store.completeStep({ id, step: "notify", from: "summarized", to: "notified" });

    expect(store.resetForRetry({ id, from: "notify" })).toBe(false);
    expect(store.resetForRetry({ id, from: "summarize" })).toBe(true);
    expect(store.getMemo(id)).toMatchObject({ state: "acted", summary: null });
    expect(store.listStepRecords(id).map((r) => r.step)).toEqual([]);

    const healthy = seedMemo(store, "notified");
    expect(store.resetForRetry({ id: healthy.id, from: "summarize" })).toBe(false);
  });

  it("resetForRetry from act or transcribe clears the old route, from notify keeps it", () => {
    const { store, db } = testStore();
    const failedWithRoute = (from: "transcribe" | "act" | "notify") => {
      const { id } = seedMemo(store, "acted");
      db.query("UPDATE memos SET route = 'journal' WHERE id = ?").run(id);
      store.markStepFailed({ id, step: from, error: "boom" });
      store.resetForRetry({ id, from });
      return store.getMemo(id)?.route;
    };
    expect(failedWithRoute("act")).toBeNull();
    expect(failedWithRoute("transcribe")).toBeNull();
    expect(failedWithRoute("notify")).toBe("journal");
  });

  it("resetForRetry only rewinds a failed memo", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "acted");
    expect(store.resetForRetry({ id, from: "act" })).toBe(false);
    expect(store.getMemo(id)?.state).toBe("acted");
  });
});

const thread = (id: string, title = "first words") => ({
  id,
  kind: "chat" as const,
  title,
});

function act(store: ReturnType<typeof testStore>["store"], id: string, patch: MemoPatch) {
  store.markStepStarted({ id, step: "act" });
  return store.completeStep({ id, step: "act", from: "transcribed", to: "acted", patch });
}

describe("threads", () => {
  it("upserts the thread and sets the memo's thread_id in the act completion", () => {
    const { store, db, clock } = testStore();
    const { id } = seedMemo(store, "transcribed");
    expect(store.getMemo(id)?.threadId).toBeNull();
    expect(act(store, id, { destinationRef: id, thread: thread(id) })).toBe(true);
    expect(store.getMemo(id)?.threadId).toBe(id);
    expect(db.query("SELECT * FROM threads").all()).toEqual([
      {
        id,
        kind: "chat",
        title: "first words",
        created_at: clock.now().toISOString(),
        updated_at: clock.now().toISOString(),
        last_memo_id: id,
      },
    ]);
  });

  it("keeps kind, title and created_at of an existing thread and moves updated_at and last_memo_id", () => {
    const { store, db, clock } = testStore();
    const first = seedMemo(store, "transcribed");
    act(store, first.id, { thread: thread("session", "first words") });
    const created = clock.now().toISOString();
    clock.advance(5_000);
    const second = seedMemo(store, "transcribed");
    act(store, second.id, {
      thread: { id: "session", kind: "hermes", title: "other words" },
    });
    expect(store.getMemo(second.id)?.threadId).toBe("session");
    expect(db.query("SELECT * FROM threads").all()).toEqual([
      {
        id: "session",
        kind: "chat",
        title: "first words",
        created_at: created,
        updated_at: clock.now().toISOString(),
        last_memo_id: second.id,
      },
    ]);
  });

  it("writes no thread when the compare-and-set loses", () => {
    const { store, db } = testStore();
    const { id } = seedMemo(store, "acted");
    expect(act(store, id, { thread: thread("session") })).toBe(false);
    expect(db.query("SELECT * FROM threads").all()).toEqual([]);
    expect(store.getMemo(id)?.threadId).toBeNull();
  });

  it("resetForRetry from act unlinks the memo from its own session but keeps the thread", () => {
    const { store, db } = testStore();
    const { id } = seedMemo(store, "transcribed");
    act(store, id, { thread: thread(id) });
    store.markStepStarted({ id, step: "notify" });
    store.markStepFailed({ id, step: "notify", error: "boom" });

    store.resetForRetry({ id, from: "notify" });
    expect(store.getMemo(id)?.threadId).toBe(id);

    store.markStepFailed({ id, step: "act", error: "boom" });
    store.resetForRetry({ id, from: "act" });
    expect(store.getMemo(id)?.threadId).toBeNull();
    expect(db.query("SELECT id FROM threads").all()).toEqual([{ id }]);
  });

  it("resetForRetry keeps the thread of a memo created to continue it", () => {
    const { store } = testStore();
    const memo = seedMemo(store, "transcribed");
    const continued = store.createTextMemo({
      id: crypto.randomUUID(),
      mode: "chat",
      device: "iphone",
      startedAt: "2026-01-01T00:00:00.000Z",
      text: "and then?",
      threadId: memo.id,
    }).memo;
    expect(continued.threadId).toBe(memo.id);

    act(store, continued.id, { thread: thread(memo.id) });
    store.markStepFailed({ id: continued.id, step: "act", error: "boom" });
    store.resetForRetry({ id: continued.id, from: "act" });
    expect(store.getMemo(continued.id)?.threadId).toBe(memo.id);
  });

  it("rejects an unknown kind", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "transcribed");
    expect(() =>
      act(store, id, { thread: { id: "s", kind: "other" as never, title: "t" } }),
    ).toThrow();
  });

  it("backfills a thread for each existing hermes memo and links it, leaving other memos alone", () => {
    const db = new Database(":memory:");
    migrate(db, MIGRATIONS.slice(0, 5));
    const insert = db.query(
      `INSERT INTO memos (id, mode, device, started_at, state, transcript, route, destination_ref, created_at, updated_at)
       VALUES (?, ?, 'iphone', 't', ?, ?, ?, ?, ?, ?)`,
    );
    const long = `${"word ".repeat(30)}end`;
    insert.run("h1", "hermes", "notified", "buy\nmilk", "hermes", "h1", "c1", "u1");
    insert.run("h2", "auto", "notified", long, "hermes", "h2", "c2", "u2");
    insert.run("j1", "journal", "notified", "dear diary", "journal", "note.md", "c3", "u3");
    insert.run("h3", "hermes", "transcribed", "not acted yet", "hermes", null, "c4", "u4");

    const store = createSqliteMemoStore({ db, clock: testStore().clock });
    expect(db.query("SELECT * FROM threads ORDER BY id").all()).toEqual([
      {
        id: "h1",
        kind: "hermes",
        title: "buy milk",
        created_at: "c1",
        updated_at: "u1",
        last_memo_id: "h1",
      },
      {
        id: "h2",
        kind: "hermes",
        title: `${"word ".repeat(11)}word…`,
        created_at: "c2",
        updated_at: "u2",
        last_memo_id: "h2",
      },
    ]);
    expect(store.getMemo("h1")?.threadId).toBe("h1");
    expect(store.getMemo("h2")?.threadId).toBe("h2");
    expect(store.getMemo("j1")?.threadId).toBeNull();
    expect(store.getMemo("h3")?.threadId).toBeNull();
  });
});

describe("route decisions history", () => {
  it("keeps the table for old rows: it rejects an unknown source or outcome and cascades with the memo", () => {
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
    expect(db.query("SELECT * FROM route_decisions WHERE memo_id = ?").all(id)).toEqual([]);
  });

  it("is never written by a step", () => {
    const { store, db } = testStore();
    const { id } = seedMemo(store, "transcribed");
    store.markStepStarted({ id, step: "act" });
    store.completeStep({
      id,
      step: "act",
      from: "transcribed",
      to: "acted",
      patch: { kind: "task" },
    });
    expect(db.query("SELECT * FROM route_decisions").all()).toEqual([]);
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
    expect(db.query("SELECT * FROM route_decisions WHERE memo_id = ?").all(id)).toEqual([]);
    expect(store.getMemo(id)?.state).toBe("transcribed");
  });

  it("indexes the columns the stats reads filter on", () => {
    const db = new Database(":memory:");
    createSqliteMemoStore({ db, clock: testStore().clock });
    const plan = (sql: string) =>
      db
        .query<{ detail: string }, []>(`EXPLAIN QUERY PLAN ${sql}`)
        .all()
        .map((row) => row.detail)
        .join("\n");
    expect(plan("SELECT created_at FROM memos WHERE created_at >= 'x'")).toContain(
      "memos_created_at",
    );
    expect(plan("SELECT step FROM memo_steps WHERE started_at >= 'x'")).toContain(
      "memo_steps_started_at",
    );
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

  describe("14: Hermes decides", () => {
    const PARKED = "parked before routing moved to Hermes";
    const userVersion = (db: Database) =>
      db.query<{ user_version: number }, []>("PRAGMA user_version").get()?.user_version;

    /** A database as it stood at version 13, with one memo per state the migration treats differently. */
    function version13() {
      const db = new Database(":memory:");
      migrate(db, MIGRATIONS.slice(0, 13));
      expect(userVersion(db)).toBe(13);
      const insert = db.query(
        `INSERT INTO memos (id, mode, device, started_at, state, transcript, route, done, deleted_at, created_at, updated_at)
         VALUES (?, 'auto', 'iphone', 't', ?, 'kauf Milch', ?, ?, ?, 'c', 'u')`,
      );
      insert.run("open", "needs_route", null, 0, null);
      insert.run("done", "needs_route", null, 1, null);
      insert.run("deleted", "needs_route", null, 0, "2026-01-01T00:00:00.000Z");
      insert.run("routed", "routed", "hermes", 0, null);
      insert.run("summarized", "summarized", "hermes", 0, null);
      db.query(
        `INSERT INTO route_decisions (memo_id, created_at, source, outcome, reason)
         VALUES ('open', 'c', 'decide', 'needs_route', 'low confidence (0.60)')`,
      ).run();
      db.query(
        `INSERT INTO memo_steps (memo_id, step, status, started_at, finished_at, attempts)
         VALUES ('open', 'route', 'done', 'c', 'c', 1)`,
      ).run();
      return db;
    }

    const stateOf = (db: Database, id: string) =>
      db
        .query<{ state: string; failed_step: string | null; error: string | null }, [string]>(
          "SELECT state, failed_step, error FROM memos WHERE id = ?",
        )
        .get(id);

    it("fails an open needs_route memo at act with a failed act step, leaving done and deleted ones alone", () => {
      const db = version13();
      migrate(db);
      expect(userVersion(db)).toBe(14);

      expect(stateOf(db, "open")).toEqual({ state: "failed", failed_step: "act", error: PARKED });
      expect(
        db
          .query(
            "SELECT step, status, error, started_at, finished_at, attempts FROM memo_steps WHERE memo_id = 'open' AND step = 'act'",
          )
          .all(),
      ).toEqual([
        {
          step: "act",
          status: "failed",
          error: PARKED,
          started_at: "u",
          finished_at: "u",
          attempts: 1,
        },
      ]);
      expect(stateOf(db, "done")).toEqual({ state: "needs_route", failed_step: null, error: null });
      expect(stateOf(db, "deleted")).toEqual({
        state: "needs_route",
        failed_step: null,
        error: null,
      });
      expect(
        db.query("SELECT 1 FROM memo_steps WHERE memo_id IN ('done', 'deleted')").all(),
      ).toEqual([]);
    });

    it("moves routed to transcribed, leaves summarized alone and keeps route_decisions untouched", () => {
      const db = version13();
      migrate(db);
      expect(stateOf(db, "routed")?.state).toBe("transcribed");
      expect(stateOf(db, "summarized")?.state).toBe("summarized");
      expect(
        db.query("SELECT memo_id, source, outcome, reason FROM route_decisions").all(),
      ).toEqual([
        {
          memo_id: "open",
          source: "decide",
          outcome: "needs_route",
          reason: "low confidence (0.60)",
        },
      ]);
      expect(
        db.query("SELECT kind, actions_json FROM memos WHERE id = 'summarized'").get(),
      ).toEqual({ kind: null, actions_json: null });
      expect(db.query("SELECT hermes_headline FROM memos WHERE id = 'summarized'").get()).toEqual({
        hermes_headline: null,
      });
    });

    it("lets the migrated memo retry from act like any failed memo, then drive on", () => {
      const db = version13();
      const store = createSqliteMemoStore({ db, clock: testStore().clock });
      expect(userVersion(db)).toBe(MIGRATIONS.length);
      expect(store.getMemo("open")).toMatchObject({
        state: "failed",
        failedStep: "act",
        error: PARKED,
        kind: null,
        actions: [],
      });

      expect(store.resetForRetry({ id: "open", from: "act" })).toBe(true);
      expect(store.getMemo("open")).toMatchObject({
        state: "transcribed",
        failedStep: null,
        error: null,
        transcript: "kauf Milch",
      });
      expect(store.listStepRecords("open").map((r) => r.step)).toEqual(["route"]);

      store.markStepStarted({ id: "open", step: "act" });
      expect(
        store.completeStep({
          id: "open",
          step: "act",
          from: "transcribed",
          to: "acted",
          patch: { replyText: "ok", kind: "task", actions: ["web_search"] },
        }),
      ).toBe(true);
      expect(store.getMemo("open")).toMatchObject({ state: "acted", kind: "task" });
    });

    it("indexes memos.kind", () => {
      const db = new Database(":memory:");
      createSqliteMemoStore({ db, clock: testStore().clock });
      expect(
        db
          .query<{ detail: string }, []>(
            "EXPLAIN QUERY PLAN SELECT id FROM memos WHERE kind = 'task'",
          )
          .all()
          .map((row) => row.detail)
          .join("\n"),
      ).toContain("memos_kind");
    });
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

const files = (block: number, tag: string): ReplyAsset[] =>
  (["svg", "png"] as const).flatMap((format) =>
    (["light", "dark"] as const).map((scheme) => ({
      id: `${tag}-${format}-${scheme}`,
      block,
      format,
      scheme,
      width: 300,
      height: 120,
    })),
  );

type Store = ReturnType<typeof testStore>["store"];

/** Stages `assets` for `replyText` and commits the act step with it: the way a handler's render reaches the rows. */
function commitReply(params: {
  store: Store;
  id: string;
  replyText: string;
  assets?: ReplyAsset[];
  failed?: boolean;
  from?: "transcribed" | "acted";
  settled?: string[];
}) {
  const {
    store,
    id,
    replyText,
    assets = [],
    failed = false,
    from = "transcribed",
    settled,
  } = params;
  store.stageReplyAssets(id, {
    replyText,
    assets,
    failed,
    onSettled: (outcome) => void settled?.push(`${replyText}:${outcome}`),
  });
  return store.completeStep({ id, step: "act", from, to: "acted", patch: { replyText } });
}

const candidates = (store: Store) => store.listReplyAssetCandidates({ limit: 10 }).map((c) => c.id);

describe("reply assets", () => {
  it("a memo has no blocks until a reply commits with assets; they group per block and come back ordered", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "transcribed");
    expect(store.getMemo(id)?.replyBlocks).toEqual([]);

    expect(
      commitReply({ store, id, replyText: "r", assets: [...files(2, "b"), ...files(0, "a")] }),
    ).toBe(true);
    expect(store.getMemo(id)?.replyBlocks).toEqual([
      {
        index: 0,
        kind: "mermaid",
        width: 300,
        height: 120,
        svg: { light: "a-svg-light", dark: "a-svg-dark" },
        png: { light: "a-png-light", dark: "a-png-dark" },
      },
      {
        index: 2,
        kind: "mermaid",
        width: 300,
        height: 120,
        svg: { light: "b-svg-light", dark: "b-svg-dark" },
        png: { light: "b-png-light", dark: "b-png-dark" },
      },
    ]);
    expect(store.getReplyAsset(id, "a-png-dark")).toMatchObject({ block: 0, format: "png" });
    expect(store.getReplyAsset(id, "nope")).toBeNull();
    expect(store.listMemos({ limit: 5 }).memos[0]?.replyBlocks).toHaveLength(2);
  });

  it("a stored row that no longer parses drops the blocks with a warning instead of failing the read", async () => {
    const { store, db } = testStore();
    const { id } = seedMemo(store, "transcribed");
    commitReply({ store, id, replyText: "r", assets: files(0, "a") });
    db.query("UPDATE reply_assets SET width = 'wide' WHERE id = 'a-svg-light'").run();
    const { result, lines } = await captureLogs(async () => store.getMemo(id));
    expect(result?.replyBlocks).toEqual([]);
    expect(lines.map((l) => l["event"])).toEqual(["memo.reply_assets_invalid"]);
  });

  it("staged assets are invisible (no row, no asset) until the reply commits, then settle as committed once", () => {
    const { store, db } = testStore();
    const { id } = seedMemo(store, "transcribed");
    const settled: string[] = [];
    store.markStepStarted({ id, step: "act" });
    expect(
      store.stageReplyAssets(id, {
        replyText: "r",
        assets: files(0, "a"),
        failed: false,
        onSettled: (outcome) => void settled.push(outcome),
      }),
    ).toBe(true);
    expect(db.query("SELECT 1 FROM reply_assets").all()).toEqual([]);
    expect(store.getMemo(id)?.replyBlocks).toEqual([]);
    expect(store.getReplyAsset(id, "a-svg-light")).toBeNull();

    store.completeStep({
      id,
      step: "act",
      from: "transcribed",
      to: "acted",
      patch: { replyText: "r" },
    });
    expect(store.getReplyAsset(id, "a-svg-light")).not.toBeNull();
    expect(store.getMemo(id)?.replyBlocks).toHaveLength(1);
    expect(settled).toEqual(["committed"]);
    expect(
      store.stageReplyAssets("unknown", {
        replyText: "r",
        assets: [],
        failed: false,
        onSettled() {},
      }),
    ).toBe(false);
  });

  it("a winning commit replaces the earlier reply's rows; a reply with no staged assets leaves none", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "transcribed");
    store.markStepStarted({ id, step: "act" });
    commitReply({ store, id, replyText: "r1", assets: files(0, "old") });
    store.transition({ id, from: "acted", to: "transcribed" });
    commitReply({
      store,
      id,
      replyText: "r2",
      assets: [...files(0, "new"), ...files(1, "half").slice(0, 3)],
    });
    expect(store.getReplyAsset(id, "old-svg-light")).toBeNull();
    expect(store.getMemo(id)?.replyBlocks.map((b) => b.index)).toEqual([0]);

    store.transition({ id, from: "acted", to: "transcribed" });
    commitReply({ store, id, replyText: "r3" });
    expect(store.getMemo(id)?.replyBlocks).toEqual([]);
  });

  it("a lost compare-and-set leaves the earlier committed reply's assets and settles the new ones as discarded", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "transcribed");
    const settled: string[] = [];
    commitReply({ store, id, replyText: "r1", assets: files(0, "old"), settled });

    // The step ran again from a stale state and lost.
    expect(
      commitReply({
        store,
        id,
        replyText: "r2",
        assets: files(0, "new"),
        from: "transcribed",
        settled,
      }),
    ).toBe(false);
    expect(settled).toEqual(["r1:committed", "r2:discarded"]);
    expect(store.getMemo(id)?.replyBlocks.map((b) => b.svg.light)).toEqual(["old-svg-light"]);
    expect(store.getReplyAsset(id, "new-svg-light")).toBeNull();
  });

  it("a completeStep that throws rolls back and settles the staging as discarded, once", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "transcribed");
    const settled: string[] = [];
    store.markStepStarted({ id, step: "act" });
    store.stageReplyAssets(id, {
      replyText: "r",
      // An asset the table refuses makes the commit's transaction throw.
      assets: [{ ...(files(0, "a")[0] as ReplyAsset), format: "gif" as never }],
      failed: false,
      onSettled: (outcome) => void settled.push(outcome),
    });

    expect(() =>
      store.completeStep({
        id,
        step: "act",
        from: "transcribed",
        to: "acted",
        patch: { replyText: "r" },
      }),
    ).toThrow();
    expect(settled).toEqual(["discarded"]);
    expect(store.getMemo(id)).toMatchObject({ state: "transcribed", replyText: null });
    expect(store.getMemo(id)?.replyBlocks).toEqual([]);

    // Nothing is left staged: a later commit of the same reply settles nothing again.
    store.completeStep({
      id,
      step: "act",
      from: "transcribed",
      to: "acted",
      patch: { replyText: "r" },
    });
    expect(settled).toEqual(["discarded"]);
  });

  it("only the latest staging of a memo settles with a commit; a newer one discards the older", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "transcribed");
    const settled: string[] = [];
    store.markStepStarted({ id, step: "act" });
    for (const replyText of ["r1", "r2"]) {
      store.stageReplyAssets(id, {
        replyText,
        assets: files(0, replyText),
        failed: false,
        onSettled: (outcome) => void settled.push(`${replyText}:${outcome}`),
      });
    }
    expect(settled).toEqual(["r1:discarded"]);

    // A commit of a reply nothing was staged for leaves the staging of the newer one alone.
    store.transition({ id, from: "transcribed", to: "needs_route" });
    expect(
      store.completeStep({
        id,
        step: "act",
        from: "transcribed",
        to: "acted",
        patch: { replyText: "r1" },
      }),
    ).toBe(false);
    expect(settled).toEqual(["r1:discarded"]);

    store.transition({ id, from: "needs_route", to: "transcribed" });
    store.completeStep({
      id,
      step: "act",
      from: "transcribed",
      to: "acted",
      patch: { replyText: "r2" },
    });
    expect(settled).toEqual(["r1:discarded", "r2:committed"]);
    expect(store.getMemo(id)?.replyBlocks).toHaveLength(1);
  });

  it("resetForRetry from act drops the rows and discards a staging once; a reset from a later step leaves both", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "transcribed");
    const settled: string[] = [];
    commitReply({ store, id, replyText: "x", assets: files(0, "a"), settled });
    store.stageReplyAssets(id, {
      replyText: "y",
      assets: files(0, "b"),
      failed: false,
      onSettled: (outcome) => void settled.push(`y:${outcome}`),
    });

    store.markStepStarted({ id, step: "notify" });
    store.markStepFailed({ id, step: "notify", error: "boom" });
    store.resetForRetry({ id, from: "notify" });
    expect(store.getMemo(id)?.replyBlocks).toHaveLength(1);
    expect(settled).toEqual(["x:committed"]);

    store.markStepFailed({ id, step: "act", error: "boom" });
    store.resetForRetry({ id, from: "act" });
    expect(settled).toEqual(["x:committed", "y:discarded"]);
    expect(store.getMemo(id)?.replyBlocks).toEqual([]);

    // Nothing is left to settle: a stale commit of the old reply discards nothing a second time.
    store.transition({ id, from: "transcribed", to: "needs_route" });
    expect(
      store.completeStep({
        id,
        step: "act",
        from: "transcribed",
        to: "acted",
        patch: { replyText: "y" },
      }),
    ).toBe(false);
    expect(settled).toEqual(["x:committed", "y:discarded"]);
  });

  it("purge removes the rows with the memo and forgets a staging", () => {
    const { store, clock } = testStore();
    const { id } = seedMemo(store, "transcribed");
    const settled: string[] = [];
    commitReply({ store, id, replyText: "x", assets: files(0, "b"), settled });
    store.stageReplyAssets(id, {
      replyText: "y",
      assets: files(0, "c"),
      failed: false,
      onSettled: (outcome) => void settled.push(`y:${outcome}`),
    });
    store.markDeleted({ id, at: clock.now().toISOString() });
    expect(store.purge(id)).toBe(true);
    expect(store.getReplyAsset(id, "b-svg-light")).toBeNull();
    expect(settled).toEqual(["x:committed"]);
  });

  describe("failed marker", () => {
    const mermaid = "```mermaid\nA-->B\n```";

    it("a commit staged as failed hides the memo from the backfill candidates; a changed reply clears it", () => {
      const { store } = testStore();
      const { id } = seedMemo(store, "transcribed");
      commitReply({ store, id, replyText: mermaid, failed: true });
      expect(candidates(store)).toEqual([]);

      store.transition({ id, from: "acted", to: "transcribed" });
      commitReply({ store, id, replyText: `${mermaid} changed` });
      expect(candidates(store)).toEqual([id]);
    });

    it("a reply committed without a staging is a candidate; marking applies only to the reply it names", () => {
      const { store } = testStore();
      const { id } = seedMemo(store, "transcribed");
      commitReply({ store, id, replyText: mermaid });
      expect(candidates(store)).toEqual([id]);

      expect(store.markReplyAssetsFailed({ id, replyText: "another reply" })).toBe(false);
      expect(candidates(store)).toEqual([id]);
      expect(store.markReplyAssetsFailed({ id, replyText: mermaid })).toBe(true);
      expect(candidates(store)).toEqual([]);
      expect(store.markReplyAssetsFailed({ id: "unknown", replyText: mermaid })).toBe(false);
    });

    it("resetForRetry from act clears it", () => {
      const { store, db } = testStore();
      const { id } = seedMemo(store, "transcribed");
      commitReply({ store, id, replyText: mermaid, failed: true });
      store.markStepFailed({ id, step: "act", error: "boom" });
      store.resetForRetry({ id, from: "act" });
      expect(
        db.query("SELECT reply_assets_failed AS failed FROM memos WHERE id = ?").get(id),
      ).toEqual({ failed: 0 });
    });
  });
});
