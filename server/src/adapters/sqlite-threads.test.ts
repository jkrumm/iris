import { describe, expect, it } from "bun:test";
import { testStore } from "../memo/test-support.js";

type TestStore = ReturnType<typeof testStore>;

function addThread(
  { db }: TestStore,
  thread: { id: string; kind?: "chat" | "hermes"; updatedAt: string; lastMemoId?: string },
) {
  db.query(
    `INSERT INTO threads (id, kind, title, created_at, updated_at, last_memo_id)
     VALUES (?, ?, ?, ?, ?, ?)`,
  ).run(
    thread.id,
    thread.kind ?? "hermes",
    `title ${thread.id}`,
    "2026-01-01T00:00:00.000Z",
    thread.updatedAt,
    thread.lastMemoId ?? null,
  );
}

const ids = (page: { threads: { id: string }[] }) => page.threads.map((t) => t.id);

describe("getThread", () => {
  it("returns the thread, or null", () => {
    const ctx = testStore();
    addThread(ctx, {
      id: "a",
      kind: "chat",
      updatedAt: "2026-01-02T00:00:00.000Z",
      lastMemoId: "m",
    });
    expect(ctx.store.getThread("a")).toEqual({
      id: "a",
      kind: "chat",
      title: "title a",
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-02T00:00:00.000Z",
      lastMemoId: "m",
    });
    expect(ctx.store.getThread("missing")).toBeNull();
  });
});

describe("listThreads", () => {
  it("lists the newest update first, ties by id descending, and filters by kind", () => {
    const ctx = testStore();
    addThread(ctx, { id: "old", updatedAt: "2026-01-01T00:00:00.000Z" });
    addThread(ctx, { id: "chat", kind: "chat", updatedAt: "2026-01-03T00:00:00.000Z" });
    addThread(ctx, { id: "tie-a", updatedAt: "2026-01-02T00:00:00.000Z" });
    addThread(ctx, { id: "tie-b", updatedAt: "2026-01-02T00:00:00.000Z" });

    expect(ids(ctx.store.listThreads({ limit: 10 }))).toEqual(["chat", "tie-b", "tie-a", "old"]);
    expect(ids(ctx.store.listThreads({ limit: 10, kind: "chat" }))).toEqual(["chat"]);
    expect(ids(ctx.store.listThreads({ limit: 10, kind: "hermes" }))).toEqual([
      "tie-b",
      "tie-a",
      "old",
    ]);
  });

  it("pages with a cursor on (updated_at, id) and ends with a null cursor", () => {
    const ctx = testStore();
    for (const [id, day] of [
      ["a", 1],
      ["b", 2],
      ["c", 2],
      ["d", 3],
      ["e", 4],
    ] as const) {
      addThread(ctx, { id, updatedAt: `2026-01-0${day}T00:00:00.000Z` });
    }
    const first = ctx.store.listThreads({ limit: 2 });
    expect(ids(first)).toEqual(["e", "d"]);
    const second = ctx.store.listThreads({ limit: 2, cursor: first.nextCursor });
    expect(ids(second)).toEqual(["c", "b"]);
    const third = ctx.store.listThreads({ limit: 2, cursor: second.nextCursor });
    expect(ids(third)).toEqual(["a"]);
    expect(third.nextCursor).toBeNull();
  });

  it("keeps the cursor valid as threads are added and updated", () => {
    const ctx = testStore();
    for (const [id, day] of [
      ["a", 1],
      ["b", 2],
      ["c", 3],
      ["d", 4],
    ] as const) {
      addThread(ctx, { id, updatedAt: `2026-01-0${day}T00:00:00.000Z` });
    }
    const first = ctx.store.listThreads({ limit: 2 });
    expect(ids(first)).toEqual(["d", "c"]);

    // A new thread and a bump of an already listed one land above the cursor; an older one moves up past it.
    addThread(ctx, { id: "new", updatedAt: "2026-01-09T00:00:00.000Z" });
    ctx.db.query("UPDATE threads SET updated_at = '2026-01-08T00:00:00.000Z' WHERE id = 'd'").run();

    const second = ctx.store.listThreads({ limit: 2, cursor: first.nextCursor });
    expect(ids(second)).toEqual(["b", "a"]);
    expect(second.nextCursor).toBeNull();
  });

  it("rejects a malformed cursor", () => {
    const { store } = testStore();
    for (const cursor of ["", "not-a-cursor", Buffer.from("[1,2]").toString("base64url"), "e30"]) {
      expect(() => store.listThreads({ limit: 5, cursor })).toThrow("invalid cursor");
    }
  });
});

describe("listThreadMemos", () => {
  it("returns the memos of the thread, oldest first", () => {
    const ctx = testStore();
    const make = (id: string, threadId?: string) =>
      ctx.store.createTextMemo({
        id,
        mode: "chat",
        device: "iphone",
        startedAt: "2026-01-01T00:00:00.000Z",
        text: id,
        threadId,
      }).memo;
    addThread(ctx, { id: "t", kind: "chat", updatedAt: "2026-01-01T00:00:00.000Z" });
    make("m1", "t");
    make("other");
    make("m2", "t");
    expect(ctx.store.listThreadMemos("t").map((m) => m.id)).toEqual(["m1", "m2"]);
    expect(ctx.store.listThreadMemos("t")[0]?.threadId).toBe("t");
    expect(ctx.store.listThreadMemos("none")).toEqual([]);
  });
});

describe("listThreadReplies", () => {
  it("maps each live memo of the thread to when its act step finished", () => {
    const ctx = testStore();
    const make = (id: string, threadId?: string) =>
      ctx.store.createTextMemo({
        id,
        mode: "chat",
        device: "iphone",
        startedAt: "2026-01-01T00:00:00.000Z",
        text: id,
        threadId,
      }).memo;
    addThread(ctx, { id: "t", kind: "chat", updatedAt: "2026-01-01T00:00:00.000Z" });
    for (const id of ["m1", "m2", "m3", "gone"]) make(id, "t");
    make("other");
    const step = (memo: string, name: string, status: string, finishedAt: string | null) =>
      ctx.db
        .query(
          "INSERT INTO memo_steps (memo_id, step, status, started_at, finished_at) VALUES (?, ?, ?, ?, ?)",
        )
        .run(memo, name, status, "2026-01-01T00:00:00.000Z", finishedAt);
    step("m1", "act", "done", "2026-01-01T00:01:00.000Z");
    step("m1", "summarize", "done", "2026-01-01T00:02:00.000Z");
    step("m2", "act", "running", null);
    step("gone", "act", "done", "2026-01-01T00:03:00.000Z");
    step("other", "act", "done", "2026-01-01T00:04:00.000Z");
    ctx.store.markDeleted({ id: "gone", at: "2026-01-02T00:00:00.000Z" });

    expect(ctx.store.listThreadReplies("t")).toEqual(new Map([["m1", "2026-01-01T00:01:00.000Z"]]));
    expect(ctx.store.listThreadReplies("none")).toEqual(new Map());
  });
});
