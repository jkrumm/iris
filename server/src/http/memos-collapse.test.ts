import { describe, expect, it } from "bun:test";
import { seedMemo, transition } from "../memo/test-support.js";
import { call, testApp } from "./test-support.js";

type Ctx = ReturnType<typeof testApp>;
interface Item {
  id: string;
  state: string;
  favorite: boolean;
  archived: boolean;
  threadId?: string;
  conversation?: { id: string; title: string; turns: number };
}
interface Page {
  items: Item[];
  nextCursor: string | null;
}

const list = async (app: Ctx["app"], query = ""): Promise<Page> => {
  const res = await call(app, { path: `/v1/memos${query}` });
  expect(res.status).toBe(200);
  return (await res.json()) as Page;
};
const ids = (page: Page) => page.items.map((item) => item.id);

/** A memo that ran in `session` (a Hermes thread), settled at `notified` with its transcript. */
function turn(
  store: Ctx["store"],
  session: string,
  options: { transcript?: string; headline?: string; title?: string; settle?: boolean } = {},
) {
  const { id } = seedMemo(store, "transcribed");
  store.completeStep({
    id,
    step: "transcribe",
    from: "transcribed",
    to: "transcribed",
    patch: { transcript: options.transcript ?? "hallo" },
  });
  store.markStepStarted({ id, step: "act" });
  store.completeStep({
    id,
    step: "act",
    from: "transcribed",
    to: "acted",
    patch: { thread: { id: session, kind: "hermes", title: options.title ?? "thread title" } },
  });
  if (options.settle !== false) {
    store.completeStep({
      id,
      step: "summarize",
      from: "acted",
      to: "summarized",
      patch: options.headline
        ? { summary: { headline: options.headline, detail: "d", spoken: "s" } }
        : undefined,
    });
    transition(store, { id, from: "summarized", to: "notified" });
  }
  return id;
}

describe("GET /v1/memos?collapse=thread", () => {
  it("lists a thread of three memos as one item, its newest memo, with the conversation", async () => {
    const { app, store } = testApp();
    const first = turn(store, "talk", { headline: "Geschenkideen für Ines" });
    const second = turn(store, "talk");
    const third = turn(store, "talk");
    const alone = turn(store, "alone");

    const collapsed = await list(app, "?collapse=thread");
    expect(ids(collapsed)).toEqual([alone, third]);
    expect(collapsed.items[1]).toMatchObject({
      threadId: "talk",
      conversation: { id: first, title: "Geschenkideen für Ines", turns: 3 },
    });
    expect(collapsed.items[0]).not.toHaveProperty("conversation");

    // Without the parameter every turn is a row, as before.
    expect(ids(await list(app)).toSorted()).toEqual([alone, first, second, third].toSorted());
  });

  it("falls back to the thread's title when the first turn has no headline", async () => {
    const { app, store } = testApp();
    turn(store, "talk", { title: "Erste Frage" });
    turn(store, "talk");
    const { items } = await list(app, "?collapse=thread");
    expect(items[0]?.conversation?.title).toBe("Erste Frage");
  });

  it("sorts a conversation by its newest turn: a reply lifts it above a later memo", async () => {
    const { app, store } = testApp();
    turn(store, "talk");
    const other = turn(store, "other");
    expect(ids(await list(app, "?collapse=thread"))).toEqual([
      other,
      ids(await list(app, "?collapse=thread"))[1]!,
    ]);
    const reply = turn(store, "talk");
    const after = await list(app, "?collapse=thread");
    expect(after.items).toHaveLength(2);
    expect(after.items[0]?.id).toBe(reply);
    expect(after.items[0]?.conversation?.turns).toBe(2);
  });

  it("shows the state of the newest turn and filters read that turn", async () => {
    const { app, store } = testApp();
    turn(store, "talk");
    const running = turn(store, "talk", { settle: false });
    const page = await list(app, "?collapse=thread");
    expect(page.items).toMatchObject([{ id: running, state: "acted" }]);
    expect(ids(await list(app, "?collapse=thread&state=acted"))).toEqual([running]);
    expect(ids(await list(app, "?collapse=thread&state=notified"))).toEqual([]);
  });

  it("finds a conversation by text in any of its turns, as the one item", async () => {
    const { app, store } = testApp();
    turn(store, "talk", { transcript: "Geschenkideen für Ines" });
    turn(store, "talk", { transcript: "Ines ist 164 cm groß" });
    const newest = turn(store, "talk", { transcript: "danke" });
    turn(store, "elsewhere", { transcript: "etwas ganz anderes" });

    const hit = await list(app, "?collapse=thread&q=164");
    expect(ids(hit)).toEqual([newest]);
    expect(hit.items[0]?.conversation?.turns).toBe(3);
    // Uncollapsed, the same search is the one memo that holds the text.
    expect(await list(app, "?q=164")).toMatchObject({
      items: [{ transcript: "Ines ist 164 cm groß" }],
    });
  });

  it("pages over collapsed items without repeating or dropping one", async () => {
    const { app, store } = testApp();
    const expected: string[] = [];
    for (let i = 0; i < 4; i++) {
      turn(store, `t${i}`);
      expected.push(turn(store, `t${i}`));
      expected.push(turn(store, `single${i}`));
    }
    expected.reverse();
    const seen: string[] = [];
    let cursor = "";
    for (let pages = 0; pages < 20; pages++) {
      const page = await list(app, `?collapse=thread&limit=3${cursor}`);
      seen.push(...ids(page));
      if (page.nextCursor === null) break;
      cursor = `&cursor=${page.nextCursor}`;
    }
    expect(seen).toEqual(expected);
    expect(seen).toHaveLength(8);
  });

  it("keeps the thread filter: only conversations, still one row each", async () => {
    const { app, store } = testApp();
    turn(store, "alone");
    turn(store, "talk");
    const newest = turn(store, "talk");
    expect(ids(await list(app, "?collapse=thread&thread=true"))).toEqual([newest]);
  });

  it("answers 400 for another collapse value", async () => {
    const { app } = testApp();
    const res = await call(app, { path: "/v1/memos?collapse=all" });
    expect(res.status).toBe(400);
  });
});

describe("scope=thread", () => {
  const patch = (app: Ctx["app"], id: string, json: unknown, query = "?scope=thread") =>
    call(app, { method: "PATCH", path: `/v1/memos/${id}${query}`, json });

  it("a favorite on the conversation row covers every turn; the row stays favorite after a reply", async () => {
    const { app, store } = testApp();
    const first = turn(store, "talk");
    const second = turn(store, "talk");
    expect((await patch(app, second, { favorite: true })).status).toBe(200);
    expect(store.getMemo(first)?.favorite).toBe(true);
    expect(store.getMemo(second)?.favorite).toBe(true);

    const reply = turn(store, "talk");
    expect(store.getMemo(reply)?.favorite).toBe(false);
    const favorites = await list(app, "?collapse=thread&favorite=true");
    expect(favorites).toMatchObject({ items: [{ id: reply, favorite: true }] });
  });

  it("a memo that continues a conversation with a favorite turn is a favorite too", () => {
    const { store } = testApp();
    const first = turn(store, "talk");
    store.setFlags({ id: first, favorite: true });
    const { memo } = store.createTextMemo({
      id: crypto.randomUUID(),
      mode: "hermes",
      device: "iphone",
      startedAt: "2026-01-01T00:00:00.000Z",
      text: "und weiter",
      threadId: "talk",
    });
    expect(memo.favorite).toBe(true);
    const other = store.createTextMemo({
      id: crypto.randomUUID(),
      mode: "hermes",
      device: "iphone",
      startedAt: "2026-01-01T00:00:00.000Z",
      text: "anderes",
      threadId: "elsewhere",
    });
    expect(other.memo.favorite).toBe(false);
  });

  it("without the scope only the memo changes", async () => {
    const { app, store } = testApp();
    const first = turn(store, "talk");
    const second = turn(store, "talk");
    await patch(app, second, { archived: true }, "");
    expect(store.getMemo(first)?.archivedAt).toBeNull();
    expect(store.getMemo(second)?.archivedAt).not.toBeNull();
  });

  it("archives the conversation: it leaves the list and shows in the archive as one row", async () => {
    const { app, store } = testApp();
    turn(store, "talk");
    const second = turn(store, "talk");
    await patch(app, second, { archived: true });
    expect(ids(await list(app, "?collapse=thread"))).toEqual([]);
    expect(ids(await list(app, "?collapse=thread&archived=true"))).toEqual([second]);
  });

  it("deletes every turn at one instant and the restore brings them all back", async () => {
    const { app, store } = testApp();
    const first = turn(store, "talk");
    const second = turn(store, "talk");
    const other = turn(store, "other");

    const del = await call(app, { method: "DELETE", path: `/v1/memos/${second}?scope=thread` });
    expect(del.status).toBe(200);
    expect(store.getMemo(first)?.deletedAt).toBe(store.getMemo(second)?.deletedAt);
    expect(ids(await list(app, "?collapse=thread"))).toEqual([other]);

    const back = await call(app, {
      method: "POST",
      path: `/v1/memos/${second}/restore?scope=thread`,
    });
    expect(back.status).toBe(200);
    expect(store.getMemo(first)?.deletedAt).toBeNull();
    expect(ids(await list(app, "?collapse=thread"))).toEqual([other, second]);
  });

  it("a turn deleted earlier on its own stays deleted when the conversation is restored", async () => {
    const { app, store } = testApp();
    const first = turn(store, "talk");
    const second = turn(store, "talk");
    const third = turn(store, "talk");
    store.markDeleted({ id: first, at: "2025-12-01T00:00:00.000Z" });
    await call(app, { method: "DELETE", path: `/v1/memos/${third}?scope=thread` });
    await call(app, { method: "POST", path: `/v1/memos/${third}/restore?scope=thread` });
    expect(store.getMemo(first)?.deletedAt).not.toBeNull();
    expect(store.getMemo(second)?.deletedAt).toBeNull();
  });

  it("refuses to delete a conversation while a turn is still running, and deletes nothing", async () => {
    const { app, store } = testApp();
    const first = turn(store, "talk");
    const running = turn(store, "talk", { settle: false });
    const res = await call(app, { method: "DELETE", path: `/v1/memos/${first}?scope=thread` });
    expect(res.status).toBe(409);
    expect(store.getMemo(first)?.deletedAt).toBeNull();
    expect(store.getMemo(running)?.deletedAt).toBeNull();
  });
});
