import { describe, expect, it } from "bun:test";
import type { MemoPatch } from "../memo/memo.js";
import { parkMemo, seedMemo, testStore } from "../memo/test-support.js";
import { Database } from "bun:sqlite";
import { migrate } from "./sqlite.js";
import { MIGRATIONS } from "./sqlite-migrations.js";

const ids = (page: { memos: { id: string }[] }) => page.memos.map((m) => m.id);

/** Runs `act` on a routed memo so it joins (or starts) the thread `thread`. */
function joinThread(
  { store }: ReturnType<typeof testStore>,
  params: { thread: string; kind?: "chat" | "hermes" },
) {
  const { id } = seedMemo(store, "routed");
  const patch: MemoPatch = {
    thread: { id: params.thread, kind: params.kind ?? "hermes", title: "title" },
  };
  store.markStepStarted({ id, step: "act" });
  store.completeStep({ id, step: "act", from: "routed", to: "acted", patch });
  return id;
}

describe("setFlags", () => {
  it("starts every memo unflagged", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "notified");
    expect(store.getMemo(id)).toMatchObject({
      done: false,
      favorite: false,
      archivedAt: null,
      deletedAt: null,
    });
  });

  it("sets only the given flags and stamps archived once", () => {
    const { store, clock } = testStore();
    const { id } = seedMemo(store, "notified");
    expect(store.setFlags({ id, done: true })).toBe(true);
    expect(store.getMemo(id)).toMatchObject({ done: true, favorite: false, archivedAt: null });

    const archivedAt = clock.now().toISOString();
    store.setFlags({ id, favorite: true, archived: true });
    clock.advance(5_000);
    store.setFlags({ id, archived: true });
    expect(store.getMemo(id)).toMatchObject({ done: true, favorite: true, archivedAt });

    store.setFlags({ id, done: false, favorite: false, archived: false });
    expect(store.getMemo(id)).toMatchObject({ done: false, favorite: false, archivedAt: null });
  });

  it("moves updated_at, not the pipeline state", () => {
    const { store, clock } = testStore();
    const { id } = seedMemo(store, "notified");
    clock.advance(5_000);
    store.setFlags({ id, favorite: true });
    expect(store.getMemo(id)).toMatchObject({
      state: "notified",
      updatedAt: clock.now().toISOString(),
    });
  });

  it("refuses an unknown or soft-deleted memo", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "notified");
    expect(store.setFlags({ id: crypto.randomUUID(), done: true })).toBe(false);
    store.markDeleted({ id, at: "2026-01-01T00:00:00.000Z" });
    expect(store.setFlags({ id, done: true })).toBe(false);
    expect(store.getMemo(id)?.done).toBe(false);
  });
});

describe("markDeleted and restore", () => {
  it("keeps the first deleted_at on a repeat and clears it on restore", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "notified");
    expect(store.markDeleted({ id, at: "2026-01-01T00:00:00.000Z" })).toBe(true);
    expect(store.markDeleted({ id, at: "2026-01-01T00:05:00.000Z" })).toBe(true);
    expect(store.getMemo(id)?.deletedAt).toBe("2026-01-01T00:00:00.000Z");

    expect(store.restore(id)).toBe(true);
    expect(store.getMemo(id)?.deletedAt).toBeNull();
    expect(store.restore(id)).toBe(false);
  });

  it("reports an unknown memo", () => {
    const { store } = testStore();
    expect(store.markDeleted({ id: crypto.randomUUID(), at: "2026-01-01T00:00:00.000Z" })).toBe(
      false,
    );
    expect(store.restore(crypto.randomUUID())).toBe(false);
  });
});

describe("listMemos flags", () => {
  it("hides soft-deleted memos from items and pinned", () => {
    const { store } = testStore();
    const kept = seedMemo(store, "notified").id;
    const gone = seedMemo(store, "notified").id;
    const parked = parkMemo(store, { reason: "unsure" });
    store.markDeleted({ id: gone, at: "2026-01-01T00:00:00.000Z" });
    store.markDeleted({ id: parked, at: "2026-01-01T00:00:00.000Z" });
    const page = store.listMemos({ limit: 10 });
    expect(ids(page)).toEqual([kept]);
    expect(page.pinned).toEqual([]);
    expect(ids(store.listMemos({ limit: 10, archived: true }))).toEqual([]);
  });

  it("hides archived memos by default and lists only them with archived", () => {
    const { store } = testStore();
    const open = seedMemo(store, "notified").id;
    const archived = seedMemo(store, "notified").id;
    store.setFlags({ id: archived, archived: true });
    expect(ids(store.listMemos({ limit: 10 }))).toEqual([open]);
    expect(ids(store.listMemos({ limit: 10, archived: true }))).toEqual([archived]);
  });

  it("filters favorites, alone and with the other filters", () => {
    const { store } = testStore();
    const plain = seedMemo(store, "notified").id;
    const star = seedMemo(store, "notified").id;
    const archivedStar = seedMemo(store, "notified").id;
    store.setFlags({ id: star, favorite: true });
    store.setFlags({ id: archivedStar, favorite: true, archived: true });
    expect(ids(store.listMemos({ limit: 10, favorite: true }))).toEqual([star]);
    expect(ids(store.listMemos({ limit: 10, favorite: true, archived: true }))).toEqual([
      archivedStar,
    ]);
    expect(ids(store.listMemos({ limit: 10 }))).toEqual([star, plain]);
  });

  it("filters by the kind of the memo's thread", () => {
    const ctx = testStore();
    const chat = joinThread(ctx, { thread: "chat-1", kind: "chat" });
    const task = joinThread(ctx, { thread: "task-1", kind: "hermes" });
    const loose = seedMemo(ctx.store, "notified").id;
    expect(ids(ctx.store.listMemos({ limit: 10, kind: "chat" }))).toEqual([chat]);
    expect(ids(ctx.store.listMemos({ limit: 10, kind: "hermes" }))).toEqual([task]);
    expect(ids(ctx.store.listMemos({ limit: 10 }))).toEqual([loose, task, chat]);
  });

  it("does not pin a done needs_route memo and pages it by seq instead", () => {
    const { store } = testStore();
    const first = parkMemo(store, { reason: "unsure" });
    const second = parkMemo(store, { reason: "unsure" });
    store.setFlags({ id: first, done: true });
    const page = store.listMemos({ limit: 10 });
    expect(page.pinned.map((m) => m.id)).toEqual([second]);
    expect(ids(page)).toEqual([first]);
  });

  it("keeps the cursor stable when a pinned memo becomes done", () => {
    const { store } = testStore();
    const a = seedMemo(store, "notified").id;
    const b = seedMemo(store, "notified").id;
    const parked = parkMemo(store, { reason: "unsure" });
    const page1 = store.listMemos({ limit: 1 });
    expect(page1.pinned.map((m) => m.id)).toEqual([parked]);
    expect(ids(page1)).toEqual([b]);
    store.setFlags({ id: parked, done: true });
    const page2 = store.listMemos({ limit: 5, cursor: page1.nextCursor });
    expect(ids(page2)).toEqual([a]);
  });

  it("answers state=needs_route with the open memos pinned and the done ones paged", () => {
    const { store } = testStore();
    const done = parkMemo(store, { reason: "unsure" });
    const open = parkMemo(store, { reason: "unsure" });
    store.setFlags({ id: done, done: true });
    const page = store.listMemos({ limit: 10, state: "needs_route" });
    expect(page.pinned.map((m) => m.id)).toEqual([open]);
    expect(ids(page)).toEqual([done]);
    expect(store.listMemos({ limit: 10, state: "needs_route", cursor: "999" }).pinned).toEqual([]);
  });

  it("keeps the search index in step with a purge", () => {
    const { store } = testStore();
    const { id } = seedMemo(store, "notified");
    store.completeStep({
      id,
      step: "transcribe",
      from: "notified",
      to: "notified",
      patch: { transcript: "Kalender Termin" },
    });
    expect(ids(store.listMemos({ limit: 10, q: "kalender" }))).toEqual([id]);
    store.markDeleted({ id, at: "2026-01-01T00:00:00.000Z" });
    expect(ids(store.listMemos({ limit: 10, q: "kalender" }))).toEqual([]);
    store.purge(id);
    expect(ids(store.listMemos({ limit: 10, q: "kalender", archived: true }))).toEqual([]);
  });
});

describe("listPurgeable and purge", () => {
  it("lists memos deleted at or before the cutoff, oldest deletion first", () => {
    const { store } = testStore();
    const late = seedMemo(store, "notified").id;
    const early = seedMemo(store, "notified").id;
    const kept = seedMemo(store, "notified").id;
    store.markDeleted({ id: late, at: "2026-01-01T00:05:00.000Z" });
    store.markDeleted({ id: early, at: "2026-01-01T00:01:00.000Z" });
    expect(store.listPurgeable("2026-01-01T00:05:00.000Z")).toEqual([early, late]);
    expect(store.listPurgeable("2026-01-01T00:02:00.000Z")).toEqual([early]);
    expect(store.listPurgeable("2025-12-31T00:00:00.000Z")).toEqual([]);
    expect(store.listPurgeable("2030-01-01T00:00:00.000Z")).not.toContain(kept);
  });

  it("removes the memo with its steps, segments and decisions, and only when it is deleted", () => {
    const { store, db } = testStore();
    const id = parkMemo(store, { reason: "unsure" });
    store.recordSegment({ id, index: 0, bytes: 4, sha256: "x" });
    expect(store.purge(id)).toBe(false);
    expect(store.getMemo(id)).not.toBeNull();

    store.markDeleted({ id, at: "2026-01-01T00:00:00.000Z" });
    expect(store.purge(id)).toBe(true);
    expect(store.getMemo(id)).toBeNull();
    for (const table of ["memo_steps", "segments", "route_decisions"]) {
      expect(db.query(`SELECT * FROM ${table} WHERE memo_id = ?`).all(id)).toEqual([]);
    }
    expect(store.purge(id)).toBe(false);
  });

  it("points the thread at its newest remaining memo", () => {
    const ctx = testStore();
    const first = joinThread(ctx, { thread: "session" });
    const second = joinThread(ctx, { thread: "session" });
    expect(ctx.store.getThread("session")?.lastMemoId).toBe(second);

    ctx.store.markDeleted({ id: second, at: "2026-01-01T00:00:00.000Z" });
    ctx.store.purge(second);
    expect(ctx.store.getThread("session")?.lastMemoId).toBe(first);
  });

  it("deletes a thread left with no memos", () => {
    const ctx = testStore();
    const only = joinThread(ctx, { thread: "session" });
    ctx.store.markDeleted({ id: only, at: "2026-01-01T00:00:00.000Z" });
    ctx.store.purge(only);
    expect(ctx.store.getThread("session")).toBeNull();
    expect(ctx.db.query("SELECT * FROM threads").all()).toEqual([]);
  });
});

describe("threads and soft-deleted memos", () => {
  it("leaves soft-deleted memos out of the thread detail and moves lastMemoId off them", () => {
    const ctx = testStore();
    const first = joinThread(ctx, { thread: "session" });
    const second = joinThread(ctx, { thread: "session" });
    ctx.store.markDeleted({ id: second, at: "2026-01-01T00:00:00.000Z" });
    expect(ctx.store.listThreadMemos("session").map((m) => m.id)).toEqual([first]);
    expect(ctx.store.getThread("session")?.lastMemoId).toBe(first);

    ctx.store.restore(second);
    expect(ctx.store.listThreadMemos("session").map((m) => m.id)).toEqual([first, second]);
    expect(ctx.store.getThread("session")?.lastMemoId).toBe(second);
  });

  it("hides a thread whose memos are all soft-deleted from the list until one is restored", () => {
    const ctx = testStore();
    const only = joinThread(ctx, { thread: "session" });
    joinThread(ctx, { thread: "other" });
    ctx.store.markDeleted({ id: only, at: "2026-01-01T00:00:00.000Z" });
    expect(ctx.store.listThreads({ limit: 10 }).threads.map((t) => t.id)).toEqual(["other"]);
    expect(ctx.store.getThread("session")?.lastMemoId).toBeNull();
    ctx.store.restore(only);
    expect(
      ctx.store
        .listThreads({ limit: 10 })
        .threads.map((t) => t.id)
        .toSorted(),
    ).toEqual(["other", "session"]);
  });
});

describe("flags migration", () => {
  it("gives memos from before it no flags", () => {
    const db = new Database(":memory:");
    migrate(db, MIGRATIONS.slice(0, -1));
    db.query(
      `INSERT INTO memos (id, mode, device, started_at, state, created_at, updated_at)
       VALUES ('old', 'auto', 'iphone', 't', 'notified', 't', 't')`,
    ).run();
    migrate(db);
    expect(
      db.query("SELECT done, favorite, archived_at, deleted_at FROM memos WHERE id = 'old'").get(),
    ).toEqual({ done: 0, favorite: 0, archived_at: null, deleted_at: null });
  });
});
