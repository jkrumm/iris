import { Database } from "bun:sqlite";
import { describe, expect, it } from "bun:test";
import { MemoError } from "../memo/errors.js";
import type { MemoPatch, MemoState, ReplyAsset, Step } from "../memo/memo.js";
import { captureLogs, parkMemo, seedMemo, testStore } from "../memo/test-support.js";
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

  it("filters by route and state and combines them with q", () => {
    const { store } = testStore();
    const hermes = memoWith(store, "notified", { transcript: "Milch", route: "hermes" });
    const journal = memoWith(store, "notified", { transcript: "Milch", route: "journal" });
    const failed = memoWith(store, "acted", { transcript: "Brot", route: "hermes" });

    expect(ids(store.listMemos({ limit: 10, route: "journal" }))).toEqual([journal]);
    expect(ids(store.listMemos({ limit: 10, state: "acted" }))).toEqual([failed]);
    expect(ids(store.listMemos({ limit: 10, route: "hermes", q: "milch" }))).toEqual([hermes]);
    expect(ids(store.listMemos({ limit: 10, route: "herdr" }))).toEqual([]);
  });

  it("pins needs_route memos on the first page only and keeps them out of items", () => {
    const { store } = testStore();
    const first = parkMemo(store, { reason: "unsure" }, "Kalender Termin");
    const old = memoWith(store, "notified", { transcript: "Kalender alt" });
    const second = parkMemo(store, { reason: "unsure" }, "Milch");
    const newest = memoWith(store, "notified", { transcript: "Kalender neu" });

    const page1 = store.listMemos({ limit: 1 });
    expect(page1.pinned.map((m) => m.id)).toEqual([second, first]);
    expect(ids(page1)).toEqual([newest]);

    const page2 = store.listMemos({ limit: 1, cursor: page1.nextCursor });
    expect(page2.pinned).toEqual([]);
    expect(ids(page2)).toEqual([old]);
    expect(page2.nextCursor).toBeNull();

    const searched = store.listMemos({ limit: 10, q: "kalend" });
    expect(searched.pinned.map((m) => m.id)).toEqual([first]);
    expect(ids(searched)).toEqual([newest, old]);
  });

  it("keeps the cursor stable when a pinned memo leaves needs_route", () => {
    const { store } = testStore();
    const a = seedMemo(store, "notified").id;
    const b = seedMemo(store, "notified").id;
    const c = seedMemo(store, "notified").id;
    const parked = parkMemo(store, { reason: "unsure" });
    const page1 = store.listMemos({ limit: 2 });
    expect(ids(page1)).toEqual([c, b]);

    store.answerRoute({
      id: parked,
      decision: {
        source: "answer",
        destination: "hermes",
        tab: null,
        confidence: null,
        model: null,
        costUsd: null,
        reason: null,
        outcome: "routed",
      },
    });
    const page2 = store.listMemos({ limit: 2, cursor: page1.nextCursor });
    expect(ids(page2)).toEqual([a]);
  });

  it("lists a memo pinned on page 1 and answered before page 2 again in items, for clients to de-duplicate", () => {
    const { store } = testStore();
    const parked = parkMemo(store, { reason: "unsure" });
    const older = seedMemo(store, "notified").id;
    const newest = seedMemo(store, "notified").id;
    const page1 = store.listMemos({ limit: 1 });
    expect(page1.pinned.map((m) => m.id)).toEqual([parked]);
    expect(ids(page1)).toEqual([newest]);

    store.answerRoute({
      id: parked,
      decision: {
        source: "answer",
        destination: "hermes",
        tab: null,
        confidence: null,
        model: null,
        costUsd: null,
        reason: null,
        outcome: "routed",
      },
    });
    const page2 = store.listMemos({ limit: 5, cursor: page1.nextCursor });
    expect(page2.pinned).toEqual([]);
    expect(ids(page2)).toEqual([older, parked]);
  });

  it("answers state=needs_route entirely from pinned, with the filters applied, capped at 50", () => {
    const { store } = testStore();
    for (let i = 0; i < 52; i++) parkMemo(store, { reason: "unsure" }, i === 0 ? "alpha" : "beta");
    seedMemo(store, "notified");

    const all = store.listMemos({ limit: 10, state: "needs_route" });
    expect(all.memos).toEqual([]);
    expect(all.nextCursor).toBeNull();
    expect(all.pinned).toHaveLength(50);
    expect(store.listMemos({ limit: 10, state: "needs_route", q: "alpha" }).pinned).toHaveLength(1);
    expect(store.listMemos({ limit: 10, state: "notified" }).pinned).toEqual([]);

    // `pinned` is never paged: with a cursor it is empty, and state=needs_route has no second page.
    const later = store.listMemos({ limit: 10, state: "needs_route", cursor: "1" });
    expect(later).toEqual({ memos: [], pinned: [], pinnedTruncated: false, nextCursor: null });
  });

  it("flags a first page whose pinned memos were cut at 50, and only then", () => {
    const { store } = testStore();
    const oldest = parkMemo(store, { reason: "unsure" });
    for (let i = 1; i < 50; i++) parkMemo(store, { reason: "unsure" });
    seedMemo(store, "notified");
    const full = store.listMemos({ limit: 10 });
    expect(full.pinned).toHaveLength(50);
    expect(full.pinnedTruncated).toBe(false);

    parkMemo(store, { reason: "unsure" });
    const cut = store.listMemos({ limit: 10 });
    expect(cut.pinned).toHaveLength(50);
    expect(cut.pinned.map((m) => m.id)).not.toContain(oldest);
    expect(cut.pinnedTruncated).toBe(true);
    expect(store.listMemos({ limit: 10, route: "journal" }).pinnedTruncated).toBe(false);
    expect(store.listMemos({ limit: 10, cursor: "1" }).pinnedTruncated).toBe(false);
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

const thread = (id: string, title = "first words") => ({
  id,
  kind: "chat" as const,
  title,
});

function act(store: ReturnType<typeof testStore>["store"], id: string, patch: MemoPatch) {
  store.markStepStarted({ id, step: "act" });
  return store.completeStep({ id, step: "act", from: "routed", to: "acted", patch });
}

describe("threads", () => {
  it("upserts the thread and sets the memo's thread_id in the act completion", () => {
    const { store, db, clock } = testStore();
    const { id } = seedMemo(store, "routed");
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
    const first = seedMemo(store, "routed");
    act(store, first.id, { thread: thread("session", "first words") });
    const created = clock.now().toISOString();
    clock.advance(5_000);
    const second = seedMemo(store, "routed");
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
    const { id } = seedMemo(store, "routed");
    act(store, id, { thread: thread(id) });
    store.markStepStarted({ id, step: "summarize" });
    store.markStepFailed({ id, step: "summarize", error: "boom" });

    store.resetForRetry({ id, from: "summarize" });
    expect(store.getMemo(id)?.threadId).toBe(id);

    store.markStepFailed({ id, step: "act", error: "boom" });
    store.resetForRetry({ id, from: "act" });
    expect(store.getMemo(id)?.threadId).toBeNull();
    expect(db.query("SELECT id FROM threads").all()).toEqual([{ id }]);
  });

  it("resetForRetry keeps the thread of a memo created to continue it", () => {
    const { store } = testStore();
    const memo = seedMemo(store, "routed");
    const continued = store.createTextMemo({
      id: crypto.randomUUID(),
      mode: "chat",
      device: "iphone",
      startedAt: "2026-01-01T00:00:00.000Z",
      text: "and then?",
      threadId: memo.id,
    }).memo;
    expect(continued.threadId).toBe(memo.id);

    store.transition({ id: continued.id, from: "transcribed", to: "routed" });
    act(store, continued.id, { thread: thread(memo.id) });
    store.markStepFailed({ id: continued.id, step: "act", error: "boom" });
    store.resetForRetry({ id: continued.id, from: "route" });
    expect(store.getMemo(continued.id)?.threadId).toBe(memo.id);
  });

  it("rejects an unknown kind", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "routed");
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
    insert.run("h3", "hermes", "routed", "not acted yet", "hermes", null, "c4", "u4");

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

  it("round-trips the prefix word count and leaves it off rows without one", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "transcribed");
    store.markStepStarted({ id, step: "route" });
    store.completeStep({
      id,
      step: "route",
      from: "transcribed",
      to: "routed",
      patch: {
        route: "herdr",
        routeDecision: {
          ...decision,
          source: "prefix",
          destination: "herdr",
          tab: "w1:t1",
          prefixWords: 4,
        },
      },
    });
    store.recordCorrection({ id, decision: { ...decision, source: "correction" } });
    const [first, second] = store.listRouteDecisions(id);
    expect(first?.prefixWords).toBe(4);
    expect(second).not.toHaveProperty("prefixWords");
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
    expect(store.listMemos({ limit: 5 }).pinned[0]).toMatchObject({
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

describe("reply assets", () => {
  it("a memo has no blocks until assets are stored; they group per block and come back ordered", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "acted");
    expect(store.getMemo(id)?.replyBlocks).toEqual([]);

    expect(store.replaceReplyAssets(id, [...files(2, "b"), ...files(0, "a")])).toBe(true);
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
    const { id } = seedMemo(store, "acted");
    store.replaceReplyAssets(id, files(0, "a"));
    db.query("UPDATE reply_assets SET width = 'wide' WHERE id = 'a-svg-light'").run();
    const { result, lines } = await captureLogs(async () => store.getMemo(id));
    expect(result?.replyBlocks).toEqual([]);
    expect(lines.map((l) => l["event"])).toEqual(["memo.reply_assets_invalid"]);
  });

  it("replaces the previous set, drops a block that lacks a rendering, and refuses an unknown memo", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "acted");
    store.replaceReplyAssets(id, files(0, "old"));
    store.replaceReplyAssets(id, [...files(0, "new"), ...files(1, "half").slice(0, 3)]);
    expect(store.getReplyAsset(id, "old-svg-light")).toBeNull();
    expect(store.getMemo(id)?.replyBlocks.map((b) => b.index)).toEqual([0]);
    expect(store.replaceReplyAssets("unknown", files(0, "x"))).toBe(false);
  });

  it("resetForRetry from act drops them, purge removes them with the memo", () => {
    const { store, clock } = testStore();
    const { id } = seedMemo(store, "routed");
    act(store, id, { replyText: "x" });
    store.replaceReplyAssets(id, files(0, "a"));
    store.markStepStarted({ id, step: "summarize" });
    store.markStepFailed({ id, step: "summarize", error: "boom" });

    store.resetForRetry({ id, from: "summarize" });
    expect(store.getMemo(id)?.replyBlocks).toHaveLength(1);
    store.markStepFailed({ id, step: "summarize", error: "boom" });
    store.resetForRetry({ id, from: "act" });
    expect(store.getMemo(id)?.replyBlocks).toEqual([]);

    store.replaceReplyAssets(id, files(0, "b"));
    store.markDeleted({ id, at: clock.now().toISOString() });
    expect(store.purge(id)).toBe(true);
    expect(store.getReplyAsset(id, "b-svg-light")).toBeNull();
  });

  describe("pending assets", () => {
    const lose = (store: ReturnType<typeof testStore>["store"], id: string, replyText: string) =>
      store.completeStep({
        id,
        step: "act",
        from: "acted",
        to: "summarized",
        patch: { replyText },
      });
    const discards = () => {
      const calls: string[] = [];
      return { calls, of: (name: string) => () => void calls.push(name) };
    };

    it("a newer pending replaces the older one: only the latest reply settles", () => {
      const { store } = testStore();
      const { id } = seedMemo(store, "routed");
      const d = discards();
      store.replaceReplyAssets(id, files(0, "a"), { replyText: "r1", onDiscard: d.of("r1") });
      store.replaceReplyAssets(id, files(0, "b"), { replyText: "r2", onDiscard: d.of("r2") });

      expect(lose(store, id, "r1")).toBe(false);
      expect(d.calls).toEqual([]);
      expect(store.getMemo(id)?.replyBlocks).toHaveLength(1);

      expect(lose(store, id, "r2")).toBe(false);
      expect(lose(store, id, "r2")).toBe(false);
      expect(d.calls).toEqual(["r2"]);
      expect(store.getMemo(id)?.replyBlocks).toEqual([]);
    });

    it("resetForRetry from act settles it (rows gone, discard once); a reset from a later step leaves it", () => {
      const { store } = testStore();
      const { id } = seedMemo(store, "routed");
      act(store, id, { replyText: "x" });
      const d = discards();
      store.replaceReplyAssets(id, files(0, "a"), { replyText: "x", onDiscard: d.of("x") });

      store.markStepFailed({ id, step: "summarize", error: "boom" });
      store.resetForRetry({ id, from: "summarize" });
      expect(d.calls).toEqual([]);

      store.markStepFailed({ id, step: "act", error: "boom" });
      store.resetForRetry({ id, from: "act" });
      expect(d.calls).toEqual(["x"]);
      expect(store.getMemo(id)?.replyBlocks).toEqual([]);

      // Nothing is left to settle: a stale commit of the old reply discards nothing a second time.
      expect(lose(store, id, "x")).toBe(false);
      expect(d.calls).toEqual(["x"]);
    });

    it("purge forgets it", () => {
      const { store, clock } = testStore();
      const { id } = seedMemo(store, "routed");
      const d = discards();
      store.replaceReplyAssets(id, files(0, "a"), { replyText: "x", onDiscard: d.of("x") });
      store.markDeleted({ id, at: clock.now().toISOString() });
      expect(store.purge(id)).toBe(true);

      expect(lose(store, id, "x")).toBe(false);
      expect(d.calls).toEqual([]);
    });
  });
});
