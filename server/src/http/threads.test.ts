import { describe, expect, it } from "bun:test";
import { fakeAudio } from "../memo/test-support.js";
import { createStepHandlers } from "../pipeline/steps.js";
import { fakeDestination, fakeNotifier, fakeSummarizer } from "../ports/fakes.js";
import { call, MAC, PHONE, testApp } from "./test-support.js";

const newId = () => crypto.randomUUID();
const START = "2026-01-01T00:00:00.000Z";

/** The whole server with the real step handlers over a fake Hermes (a session per memo, `threadId` continues one). */
function setup() {
  const hermes = fakeDestination({ sessionPerMemo: true });
  const ctx = testApp({
    destinations: ["hermes"],
    handlers: (store) =>
      createStepHandlers({
        store,
        audio: fakeAudio(),
        destinations: { hermes },
        summarizer: fakeSummarizer(),
        notifier: fakeNotifier(),
      }),
  });
  return { ...ctx, hermes };
}

type Setup = ReturnType<typeof setup>;

const postText = (ctx: Setup, json: Record<string, unknown>, headers = PHONE) =>
  call(ctx.app, {
    method: "POST",
    path: "/v1/memos/text",
    headers,
    json: { id: newId(), mode: "chat", startedAt: START, text: "hello", ...json },
  });

/** Creates a typed memo and waits until the pipeline has run. */
async function say(ctx: Setup, json: Record<string, unknown> = {}) {
  const res = await postText(ctx, json);
  expect(res.status).toBe(202);
  const memo = (await res.json()) as { id: string };
  await ctx.runner.idle();
  return memo.id;
}

describe("GET /v1/threads", () => {
  it("lists the threads newest first with the wire shape", async () => {
    const ctx = setup();
    const first = await say(ctx, { text: "first thread" });
    ctx.clock.advance(1000);
    const second = await say(ctx, { mode: "auto", text: "second thread" });

    const res = await call(ctx.app, { path: "/v1/threads" });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { items: unknown[]; nextCursor: string | null };
    expect(body.nextCursor).toBeNull();
    expect(body.items).toEqual([
      {
        id: second,
        kind: "hermes",
        title: "second thread",
        createdAt: expect.any(String),
        updatedAt: expect.any(String),
        lastMemoId: second,
      },
      {
        id: first,
        kind: "chat",
        title: "first thread",
        createdAt: expect.any(String),
        updatedAt: expect.any(String),
        lastMemoId: first,
      },
    ]);
  });

  it("filters by kind and pages with a cursor", async () => {
    const ctx = setup();
    const say3 = async (mode: string, text: string) => {
      const id = await say(ctx, { mode, text });
      ctx.clock.advance(1000);
      return id;
    };
    const oldChat = await say3("chat", "memo 0");
    const task = await say3("auto", "memo 1");
    const newChat = await say3("chat", "memo 2");

    const chats = (await (await call(ctx.app, { path: "/v1/threads?kind=chat" })).json()) as {
      items: { id: string }[];
    };
    expect(chats.items.map((t) => t.id)).toEqual([newChat, oldChat]);

    const page1 = (await (await call(ctx.app, { path: "/v1/threads?limit=2" })).json()) as {
      items: { id: string }[];
      nextCursor: string;
    };
    expect(page1.items.map((t) => t.id)).toEqual([newChat, task]);
    const page2 = (await (
      await call(ctx.app, { path: `/v1/threads?limit=2&cursor=${page1.nextCursor}` })
    ).json()) as { items: { id: string }[]; nextCursor: string | null };
    expect(page2.items.map((t) => t.id)).toEqual([oldChat]);
    expect(page2.nextCursor).toBeNull();
  });

  it("is empty before any memo reached Hermes", async () => {
    const res = await call(setup().app, { path: "/v1/threads" });
    expect(await res.json()).toEqual({ items: [], nextCursor: null });
  });

  it("answers 400 for an unknown kind or a malformed cursor", async () => {
    const { app } = setup();
    for (const path of ["/v1/threads?kind=other", "/v1/threads?cursor=garbage"]) {
      const res = await call(app, { path });
      expect(res.status).toBe(400);
      expect(((await res.json()) as { error: string }).error).toBe("bad_request");
    }
  });

  it("needs a device token", async () => {
    const res = await call(setup().app, { path: "/v1/threads", headers: {} });
    expect(res.status).toBe(401);
  });
});

describe("GET /v1/threads/:id", () => {
  it("returns the thread, its memos oldest first and the conversation built from them", async () => {
    const ctx = setup();
    const first = await say(ctx, { text: "what is a mutex?" });
    ctx.clock.advance(1000);
    const second = await say(ctx, { text: "and a semaphore?", threadId: first });

    const res = await call(ctx.app, { path: `/v1/threads/${first}` });
    expect(res.status).toBe(200);
    const body = (await res.json()) as {
      thread: { id: string; kind: string; lastMemoId: string };
      memos: { id: string; threadId: string; createdAt: string; replyText: string }[];
      messages: { memoId: string; role: string; content: string; createdAt: string }[];
    };
    expect(body).not.toHaveProperty("hermesAvailable");
    expect(body.thread).toMatchObject({ id: first, kind: "chat", lastMemoId: second });
    expect(body.memos.map((m) => m.id)).toEqual([first, second]);
    expect(body.memos.every((m) => m.threadId === first)).toBe(true);
    expect(body.messages).toEqual([
      {
        memoId: first,
        role: "user",
        content: "what is a mutex?",
        createdAt: body.memos[0]?.createdAt,
      },
      { memoId: first, role: "assistant", content: "done", createdAt: expect.any(String) },
      {
        memoId: second,
        role: "user",
        content: "and a semaphore?",
        createdAt: body.memos[1]?.createdAt,
      },
      { memoId: second, role: "assistant", content: "done", createdAt: expect.any(String) },
    ]);
  });

  it("dates a reply by the end of its act step, not by the memo's last update", async () => {
    const ctx = setup();
    const id = await say(ctx);
    const act = ctx.store.listStepRecords(id).find((r) => r.step === "act");
    expect(act?.finishedAt).toEqual(expect.any(String));
    const body = (await (await call(ctx.app, { path: `/v1/threads/${id}` })).json()) as {
      messages: { role: string; createdAt: string }[];
    };
    expect(body.messages.find((m) => m.role === "assistant")?.createdAt).toBe(
      act?.finishedAt as string,
    );
  });

  it("holds a user message alone for a memo that has no reply yet", async () => {
    const ctx = setup();
    const first = await say(ctx, { text: "hello" });
    // Created but not driven: it has its transcript and no reply.
    const { memo } = ctx.store.createTextMemo({
      id: newId(),
      mode: "chat",
      device: "iphone",
      startedAt: START,
      text: "still thinking",
      threadId: first,
    });
    const body = (await (await call(ctx.app, { path: `/v1/threads/${first}` })).json()) as {
      messages: { memoId: string; role: string; content: string }[];
    };
    expect(body.messages.filter((m) => m.memoId === memo.id)).toEqual([
      expect.objectContaining({ role: "user", content: "still thinking" }),
    ]);
  });

  it("answers 404 for an unknown thread", async () => {
    const res = await call(setup().app, { path: "/v1/threads/nope" });
    expect(res.status).toBe(404);
    expect(((await res.json()) as { error: string }).error).toBe("not_found");
  });
});

describe("continuing a thread", () => {
  it("stores the thread id at creation, delivers into the session and moves the thread", async () => {
    const ctx = setup();
    const first = await say(ctx, { text: "what is a mutex?" });
    const before = ctx.store.getThread(first);
    ctx.clock.advance(5000);

    const res = await postText(ctx, { text: "and a semaphore?", threadId: first });
    expect(res.status).toBe(202);
    const created = (await res.json()) as { id: string; threadId?: string };
    expect(created.threadId).toBe(first);
    await ctx.runner.idle();

    const delivery = ctx.hermes.calls.at(-1);
    expect(delivery).toMatchObject({ transcript: "and a semaphore?", chat: true, threadId: first });
    const after = ctx.store.getThread(first);
    expect(after?.lastMemoId).toBe(created.id);
    expect(after?.updatedAt).not.toBe(before?.updatedAt);
    expect(ctx.store.getMemo(created.id)).toMatchObject({
      state: "notified",
      route: "hermes",
      threadId: first,
      destinationRef: first,
    });
  });

  it("forces the route to Hermes whatever the mode says", async () => {
    const ctx = setup();
    const first = await say(ctx, { mode: "auto" });
    const id = await say(ctx, { mode: "journal", text: "more", threadId: first });
    expect(ctx.store.getMemo(id)?.route).toBe("hermes");
    expect(ctx.store.getThread(first)?.kind).toBe("hermes");
  });

  it("answers 404 for an unknown thread, on both create routes, and stores nothing", async () => {
    const ctx = setup();
    const text = await postText(ctx, { threadId: "nope" });
    expect(text.status).toBe(404);
    const id = newId();
    const rec = await call(ctx.app, {
      method: "POST",
      path: "/v1/memos",
      json: { id, mode: "chat", startedAt: START, threadId: "nope" },
    });
    expect(rec.status).toBe(404);
    expect(((await rec.json()) as { error: string }).error).toBe("not_found");
    expect(ctx.store.getMemo(id)).toBeNull();
    expect(ctx.store.listMemos({ limit: 5 }).memos).toEqual([]);
  });

  it("takes a threadId on a recording too", async () => {
    const ctx = setup();
    const first = await say(ctx);
    const id = newId();
    const body = { id, mode: "chat", startedAt: START, threadId: first };
    const res = await call(ctx.app, { method: "POST", path: "/v1/memos", json: body });
    expect(res.status).toBe(201);
    expect(((await res.json()) as { threadId?: string }).threadId).toBe(first);

    const replay = await call(ctx.app, { method: "POST", path: "/v1/memos", json: body });
    expect(replay.status).toBe(200);
  });

  it("keeps replays idempotent and answers 409 for another thread", async () => {
    const ctx = setup();
    const a = await say(ctx, { text: "thread a" });
    const b = await say(ctx, { text: "thread b" });
    const id = newId();
    const body = { id, text: "reply", threadId: a };

    expect((await postText(ctx, body)).status).toBe(202);
    await ctx.runner.idle();
    expect((await postText(ctx, body)).status).toBe(202);

    const other = await postText(ctx, { ...body, threadId: b });
    expect(other.status).toBe(409);
    const none = await postText(ctx, { id, text: "reply" });
    expect(none.status).toBe(409);
    expect(ctx.store.getMemo(id)?.threadId).toBe(a);
  });

  it("answers 409 when a memo that continues nothing is replayed with a thread", async () => {
    const ctx = setup();
    const a = await say(ctx);
    const id = await say(ctx, { text: "plain" });
    const res = await postText(ctx, { id, text: "plain", threadId: a });
    expect(res.status).toBe(409);
  });

  it("rejects an empty threadId", async () => {
    const res = await postText(setup(), { threadId: "" });
    expect(res.status).toBe(400);
  });

  it("retrying a continuation keeps its thread", async () => {
    const ctx = setup();
    const first = await say(ctx, { text: "start" });
    ctx.hermes.calls.length = 0;
    const id = await say(ctx, { text: "again", threadId: first });
    ctx.store.markStepFailed({ id, step: "notify", error: "boom" });

    const res = await call(ctx.app, {
      method: "POST",
      path: `/v1/memos/${id}/retry`,
      json: { from: "act" },
    });
    expect(res.status).toBe(202);
    await ctx.runner.idle();
    expect(ctx.hermes.calls.map((c) => c.threadId)).toEqual([first, first]);
    expect(ctx.store.getMemo(id)?.threadId).toBe(first);
  });

  it("shows a thread to every device, like the memo list", async () => {
    const ctx = setup();
    const id = await say(ctx);
    const res = await call(ctx.app, { path: `/v1/threads/${id}`, headers: MAC });
    expect(res.status).toBe(200);
  });
});
