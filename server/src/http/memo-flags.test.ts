import { describe, expect, it } from "bun:test";
import { PURGE_AFTER_MS } from "../memo/memo.js";
import { createPurger } from "../memo/purge.js";
import { parkMemo, seedMemo } from "../memo/test-support.js";
import { fakeSpeechCache } from "../ports/fakes.js";
import { call, MAC, testApp } from "./test-support.js";

type Ctx = ReturnType<typeof testApp>;
type Json = Record<string, unknown>;

const patch = (app: Ctx["app"], id: string, json: unknown) =>
  call(app, { method: "PATCH", path: `/v1/memos/${id}`, json });
const del = (app: Ctx["app"], id: string) =>
  call(app, { method: "DELETE", path: `/v1/memos/${id}` });
const restore = (app: Ctx["app"], id: string) =>
  call(app, { method: "POST", path: `/v1/memos/${id}/restore` });
const list = async (app: Ctx["app"], query = "") => {
  const res = await call(app, { path: `/v1/memos${query}` });
  const body = (await res.json()) as { items: { id: string }[]; pinned: { id: string }[] };
  return { res, items: body.items.map((m) => m.id), pinned: body.pinned.map((m) => m.id) };
};

describe("memo wire shape", () => {
  it("always carries done, favorite and archived, and the delete fields only while deleted", async () => {
    const { app, store } = testApp();
    const { id } = seedMemo(store, "notified");
    const plain = (await (await call(app, { path: `/v1/memos/${id}` })).json()) as Json;
    expect(plain).toMatchObject({ done: false, favorite: false, archived: false });
    expect(plain).not.toHaveProperty("deletedAt");
    expect(plain).not.toHaveProperty("purgeAt");

    const deleted = (await (await del(app, id)).json()) as Json;
    expect(deleted["deletedAt"]).toBe("2026-01-01T00:00:00.000Z");
    expect(deleted["purgeAt"]).toBe(
      new Date(Date.parse("2026-01-01T00:00:00.000Z") + PURGE_AFTER_MS).toISOString(),
    );
  });
});

describe("PATCH /v1/memos/:id", () => {
  it("sets the flags and answers the memo", async () => {
    const { app, store } = testApp();
    const { id } = seedMemo(store, "notified");
    const res = await patch(app, id, { done: true, archived: true });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ id, done: true, favorite: false, archived: true });
    const back = await patch(app, id, { archived: false, favorite: true });
    expect(await back.json()).toMatchObject({ done: true, favorite: true, archived: false });
  });

  it("answers 400 for an empty body, an unknown key and a non-boolean", async () => {
    const { app, store } = testApp();
    const { id } = seedMemo(store, "notified");
    for (const body of [
      {},
      { star: true },
      { done: true, star: true },
      { done: "yes" },
      { done: 1 },
    ]) {
      const res = await patch(app, id, body);
      expect([body, res.status]).toEqual([body, 400]);
      expect(((await res.json()) as Json)["error"]).toBe("bad_request");
    }
  });

  it("answers 404 for an unknown memo and 409 bad_state for a deleted one", async () => {
    const { app, store } = testApp();
    const missing = await patch(app, crypto.randomUUID(), { done: true });
    expect(missing.status).toBe(404);

    const { id } = seedMemo(store, "notified");
    await del(app, id);
    const locked = await patch(app, id, { done: true });
    expect(locked.status).toBe(409);
    expect(((await locked.json()) as Json)["error"]).toBe("bad_state");
  });

  it("needs a token", async () => {
    const { app, store } = testApp();
    const { id } = seedMemo(store, "notified");
    const res = await call(app, {
      method: "PATCH",
      path: `/v1/memos/${id}`,
      headers: {},
      json: { done: true },
    });
    expect(res.status).toBe(401);
  });

  it("publishes a memo.updated event over SSE for the change", async () => {
    const { app, store, events } = testApp();
    const { id } = seedMemo(store, "notified");
    const seen: unknown[] = [];
    events.subscribe((e) => seen.push(e));
    await patch(app, id, { favorite: true });
    await del(app, id);
    await restore(app, id);
    expect(seen).toHaveLength(3);
    expect(seen).toEqual([
      expect.objectContaining({ id, state: "notified", flagChange: true }),
      expect.objectContaining({ id, state: "notified", flagChange: true }),
      expect.objectContaining({ id, state: "notified", flagChange: true }),
    ]);
  });
});

describe("DELETE /v1/memos/:id", () => {
  it("soft-deletes, keeps GET working and hides the memo from the list", async () => {
    const { app, store } = testApp();
    const { id } = seedMemo(store, "notified");
    const res = await del(app, id);
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ id, deletedAt: "2026-01-01T00:00:00.000Z" });

    const detail = await call(app, { path: `/v1/memos/${id}` });
    expect(detail.status).toBe(200);
    expect(await detail.json()).toMatchObject({ id, purgeAt: "2026-01-01T00:10:00.000Z" });
    expect((await list(app)).items).toEqual([]);
  });

  it("deletes a failed and a needs_route memo, refuses the rest with 409, and repeats", async () => {
    const { app, store, clock } = testApp();
    const failed = seedMemo(store, "transcribed").id;
    store.markStepFailed({ id: failed, step: "route", error: "boom" });
    const parked = parkMemo(store, { reason: "unsure" });
    for (const id of [failed, parked]) expect((await del(app, id)).status).toBe(200);
    expect((await list(app)).pinned).toEqual([]);

    const running = seedMemo(store, "routed").id;
    const refused = await del(app, running);
    expect(refused.status).toBe(409);
    expect(((await refused.json()) as Json)["error"]).toBe("bad_state");

    clock.advance(60_000);
    const again = (await (await del(app, failed)).json()) as Json;
    expect(again["deletedAt"]).toBe("2026-01-01T00:00:00.000Z");
    expect((await del(app, crypto.randomUUID())).status).toBe(404);
  });
});

describe("POST /v1/memos/:id/restore", () => {
  it("undoes a delete", async () => {
    const { app, store } = testApp();
    const { id } = seedMemo(store, "notified");
    await del(app, id);
    const res = await restore(app, id);
    expect(res.status).toBe(200);
    const body = (await res.json()) as Json;
    expect(body).not.toHaveProperty("deletedAt");
    expect(body).not.toHaveProperty("purgeAt");
    expect((await list(app)).items).toEqual([id]);
  });

  it("answers 409 when the memo is not deleted and 404 when it is unknown", async () => {
    const { app, store } = testApp();
    const { id } = seedMemo(store, "notified");
    expect((await restore(app, id)).status).toBe(409);
    expect((await restore(app, crypto.randomUUID())).status).toBe(404);
  });

  it("answers 404 once the memo was purged, and GET agrees", async () => {
    const { app, store, clock, audio, db } = testApp();
    const { id } = seedMemo(store, "notified");
    await audio.put({ id, index: 0, bytes: new Uint8Array([1]) });
    await del(app, id);
    clock.advance(PURGE_AFTER_MS);
    const purger = createPurger({ store, audio, speechCache: fakeSpeechCache(), clock });
    expect(await purger.sweep()).toEqual([id]);

    expect((await restore(app, id)).status).toBe(404);
    expect((await call(app, { path: `/v1/memos/${id}` })).status).toBe(404);
    expect(audio.files.size).toBe(0);
    expect(db.query("SELECT id FROM memos WHERE id = ?").all(id)).toEqual([]);
  });

  it("is open to every registered device, like the other memo routes", async () => {
    const { app, store } = testApp();
    const { id } = seedMemo(store, "notified");
    await del(app, id);
    expect(
      (await call(app, { method: "POST", path: `/v1/memos/${id}/restore`, headers: MAC })).status,
    ).toBe(200);
  });
});

describe("GET /v1/memos flag filters", () => {
  it("filters favorites, archived and kind and keeps deleted memos out", async () => {
    const { app, store } = testApp();
    const plain = seedMemo(store, "notified").id;
    const star = seedMemo(store, "notified").id;
    const archived = seedMemo(store, "notified").id;
    const gone = seedMemo(store, "notified").id;
    await patch(app, star, { favorite: true });
    await patch(app, archived, { archived: true });
    await del(app, gone);

    expect((await list(app)).items).toEqual([star, plain]);
    expect((await list(app, "?favorite=true")).items).toEqual([star]);
    expect((await list(app, "?archived=true")).items).toEqual([archived]);
    expect((await list(app, "?kind=chat")).items).toEqual([]);
  });

  it("filters by the thread kind", async () => {
    const { app, store } = testApp();
    const { id } = seedMemo(store, "routed");
    store.markStepStarted({ id, step: "act" });
    store.completeStep({
      id,
      step: "act",
      from: "routed",
      to: "acted",
      patch: { thread: { id, kind: "chat", title: "hi" } },
    });
    seedMemo(store, "notified");
    expect((await list(app, "?kind=chat")).items).toEqual([id]);
    expect((await list(app, "?kind=hermes")).items).toEqual([]);
  });

  it("answers 400 for an unknown value", async () => {
    const { app } = testApp();
    for (const query of ["?favorite=false", "?favorite=1", "?archived=yes", "?kind=thread"]) {
      const res = await call(app, { path: `/v1/memos${query}` });
      expect([query, res.status]).toEqual([query, 400]);
    }
  });

  it("stops pinning a needs_route memo once it is done, and keeps it in the list", async () => {
    const { app, store } = testApp();
    const parked = parkMemo(store, { reason: "unsure" });
    expect((await list(app)).pinned).toEqual([parked]);
    await patch(app, parked, { done: true });
    const after = await list(app);
    expect(after.pinned).toEqual([]);
    expect(after.items).toEqual([parked]);
  });
});

describe("threads and flags", () => {
  it("leaves a deleted memo out of the thread detail", async () => {
    const { app, store } = testApp();
    const first = seedMemo(store, "routed").id;
    const second = seedMemo(store, "routed").id;
    for (const id of [first, second]) {
      store.markStepStarted({ id, step: "act" });
      store.completeStep({
        id,
        step: "act",
        from: "routed",
        to: "acted",
        patch: { thread: { id: "session", kind: "hermes", title: "t" } },
      });
      store.transition({ id, from: "acted", to: "notified" });
    }
    await del(app, second);
    const detail = (await (await call(app, { path: "/v1/threads/session" })).json()) as {
      thread: { lastMemoId: string };
      memos: { id: string }[];
    };
    expect(detail.memos.map((m) => m.id)).toEqual([first]);
    expect(detail.thread.lastMemoId).toBe(first);
  });
});
