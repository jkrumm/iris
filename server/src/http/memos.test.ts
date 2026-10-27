import { describe, expect, it } from "bun:test";
import { call, MAC, PHONE, testApp } from "./test-support.js";

const bytes = (n = 4) => new Uint8Array(n).fill(7);
const newId = () => crypto.randomUUID();

const create = (app: ReturnType<typeof testApp>["app"], id = newId(), headers = PHONE) =>
  call(app, {
    method: "POST",
    path: "/v1/memos",
    headers,
    json: { id, mode: "auto", startedAt: "2026-01-01T00:00:00.000Z" },
  });

const put = (
  app: ReturnType<typeof testApp>["app"],
  id: string,
  n: number | string,
  body: Uint8Array = bytes(),
  headers: Record<string, string> = { ...PHONE, "content-type": "audio/mp4" },
) => call(app, { method: "PUT", path: `/v1/memos/${id}/segments/${n}`, headers, body });

describe("POST /v1/memos", () => {
  it("creates with 201 and a snake_case memo, then repeats with 200", async () => {
    const { app } = testApp();
    const id = newId();
    const first = await create(app, id);
    expect(first.status).toBe(201);
    expect(await first.json()).toMatchObject({
      id,
      mode: "auto",
      device: "iphone",
      state: "receiving",
      startedAt: "2026-01-01T00:00:00.000Z",
      failedStep: null,
      segmentCount: null,
    });
    const again = await create(app, id);
    expect(again.status).toBe(200);
  });

  it("409s for another device", async () => {
    const { app } = testApp();
    const id = newId();
    await create(app, id);
    const res = await create(app, id, MAC);
    expect(res.status).toBe(409);
    expect(await res.json()).toMatchObject({ error: "conflict" });
  });

  it("400s on a bad mode, a non-UUID id and a malformed body", async () => {
    const { app } = testApp();
    const bad = (json: unknown) => call(app, { method: "POST", path: "/v1/memos", json });
    expect((await bad({ id: newId(), mode: "nope", startedAt: "2026-01-01" })).status).toBe(400);
    const notUuid = await bad({ id: "abc", mode: "auto", startedAt: "2026-01-01" });
    expect(notUuid.status).toBe(400);
    expect(await notUuid.json()).toMatchObject({ error: "bad_request" });
    const raw = await call(app, {
      method: "POST",
      path: "/v1/memos",
      headers: { ...PHONE, "content-type": "application/json" },
      body: new TextEncoder().encode("{nope"),
    });
    expect(raw.status).toBe(400);
  });
});

describe("PUT /v1/memos/:id/segments/:n", () => {
  it("stores raw bytes with 200, repeats the same bytes with 200 and 409s different bytes", async () => {
    const { app, audio } = testApp();
    const id = newId();
    await create(app, id);
    const first = await put(app, id, 0, bytes(4));
    expect(first.status).toBe(200);
    expect(await first.text()).toBe("");
    expect((await put(app, id, 0, bytes(4))).status).toBe(200);
    const clash = await put(app, id, 0, bytes(6));
    expect(clash.status).toBe(409);
    expect(await clash.json()).toMatchObject({ error: "conflict" });
    expect(audio.files.get(`${id}/0`)?.byteLength).toBe(4);
  });

  it("accepts octet-stream and a missing content-type, rejects other types", async () => {
    const { app } = testApp();
    const id = newId();
    await create(app, id);
    const octet = { ...PHONE, "content-type": "application/octet-stream" };
    expect((await put(app, id, 0, bytes(), octet)).status).toBe(200);
    expect((await put(app, id, 1, bytes(), PHONE)).status).toBe(200);
    const json = { ...PHONE, "content-type": "application/json" };
    expect((await put(app, id, 2, bytes(), json)).status).toBe(400);
  });

  it("413s above the cap, even when Content-Length is absent or understated", async () => {
    const { app, audio } = testApp({ maxSegmentBytes: 8 });
    const id = newId();
    await create(app, id);
    expect((await put(app, id, 0, bytes(9))).status).toBe(413);
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(bytes(5));
        controller.enqueue(bytes(5));
        controller.close();
      },
    });
    const res = await app.handle(
      new Request(`http://iris.test/v1/memos/${id}/segments/1`, {
        method: "PUT",
        headers: { ...PHONE, "content-type": "audio/mp4", "content-length": "4" },
        body: stream,
        duplex: "half",
      } as RequestInit),
    );
    expect(res.status).toBe(413);
    expect(await res.json()).toMatchObject({ error: "too_large", maxBytes: 8 });
    expect(audio.files.size).toBe(0);
  });

  it("400s on an empty body or a bad index, 404s for an unknown memo", async () => {
    const { app } = testApp();
    const id = newId();
    await create(app, id);
    expect((await put(app, id, 0, new Uint8Array())).status).toBe(400);
    expect((await put(app, id, "-1")).status).toBe(400);
    expect((await put(app, id, "1.5")).status).toBe(400);
    expect((await put(app, id, "x")).status).toBe(400);
    expect((await put(app, newId(), 0)).status).toBe(404);
  });

  it("409s once the memo is completed", async () => {
    const { app } = testApp();
    const id = newId();
    await create(app, id);
    await put(app, id, 0);
    await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/complete`,
      json: { segmentCount: 1 },
    });
    const res = await put(app, id, 1);
    expect(res.status).toBe(409);
    expect(await res.json()).toMatchObject({ error: "bad_state" });
  });
});

describe("POST /v1/memos/:id/complete", () => {
  it("lists missing segments with 422, then 202s and repeats with 202", async () => {
    const { app } = testApp();
    const id = newId();
    await create(app, id);
    await put(app, id, 1);
    const missing = await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/complete`,
      json: { segmentCount: 3 },
    });
    expect(missing.status).toBe(422);
    expect(await missing.json()).toMatchObject({ error: "missing_segments", missing: [0, 2] });

    await put(app, id, 0);
    await put(app, id, 2);
    const done = await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/complete`,
      json: { segmentCount: 3 },
    });
    expect(done.status).toBe(202);
    expect(await done.json()).toMatchObject({ state: "received", segmentCount: 3 });
    const repeat = await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/complete`,
      json: { segmentCount: 3 },
    });
    expect(repeat.status).toBe(202);
  });

  it("409s a different count after completion and 404s unknown memos", async () => {
    const { app } = testApp();
    const id = newId();
    await create(app, id);
    await put(app, id, 0);
    const path = `/v1/memos/${id}/complete`;
    await call(app, { method: "POST", path, json: { segmentCount: 1 } });
    expect((await call(app, { method: "POST", path, json: { segmentCount: 2 } })).status).toBe(409);
    const unknown = await call(app, {
      method: "POST",
      path: `/v1/memos/${newId()}/complete`,
      json: { segmentCount: 1 },
    });
    expect(unknown.status).toBe(404);
  });
});

describe("POST /v1/memos/:id/retry", () => {
  it("202s a failed memo and 409s one that is not failed", async () => {
    const { app } = testApp({
      handlers: {
        transcribe: async () => {
          throw new Error("stt down");
        },
      },
    });
    const id = newId();
    await create(app, id);
    await put(app, id, 0);
    const retryPath = `/v1/memos/${id}/retry`;
    const early = await call(app, {
      method: "POST",
      path: retryPath,
      json: { from: "transcribe" },
    });
    expect(early.status).toBe(409);

    await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/complete`,
      json: { segmentCount: 1 },
    });
    const failed = await call(app, { path: `/v1/memos/${id}/result?wait=5` });
    expect(failed.status).toBe(200);
    expect(await failed.json()).toMatchObject({ state: "failed", failedStep: "transcribe" });

    const res = await call(app, { method: "POST", path: retryPath, json: { from: "transcribe" } });
    expect(res.status).toBe(202);
    expect(await res.json()).toMatchObject({ id });
  });

  it("400s an unknown step name", async () => {
    const { app } = testApp();
    const res = await call(app, {
      method: "POST",
      path: `/v1/memos/${newId()}/retry`,
      json: { from: "nope" },
    });
    expect(res.status).toBe(400);
  });
});

describe("GET /v1/memos", () => {
  it("404s the detail of an unknown memo with the error shape", async () => {
    const { app } = testApp();
    const res = await call(app, { path: `/v1/memos/${newId()}` });
    expect(res.status).toBe(404);
    expect(await res.json()).toMatchObject({ error: "not_found", message: expect.any(String) });
  });

  it("returns detail with steps and the received segment count before complete", async () => {
    const { app } = testApp();
    const id = newId();
    await create(app, id);
    await put(app, id, 0);
    await put(app, id, 1);
    const res = await call(app, { path: `/v1/memos/${id}` });
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ id, segmentCount: 2, steps: [] });
  });

  it("rejects a bad cursor and a non-numeric limit with 400", async () => {
    const { app } = testApp();
    expect((await call(app, { path: "/v1/memos?cursor=abc" })).status).toBe(400);
    expect((await call(app, { path: "/v1/memos?limit=abc" })).status).toBe(400);
  });
});

describe("GET /v1/memos/:id/result", () => {
  it("202s a pending memo immediately with wait=0 and 200s a ready one", async () => {
    const { app, store } = testApp();
    const id = newId();
    await create(app, id);
    const pending = await call(app, { path: `/v1/memos/${id}/result` });
    expect(pending.status).toBe(202);
    expect(await pending.json()).toMatchObject({ state: "receiving" });

    store.markReceived({ id, segmentCount: 1 });
    for (const [from, to] of [
      ["received", "transcribed"],
      ["transcribed", "needs_route"],
    ] as const) {
      store.transition({ id, from, to });
    }
    const parked = await call(app, { path: `/v1/memos/${id}/result` });
    expect(parked.status).toBe(200);
    expect(await parked.json()).toMatchObject({ state: "needs_route" });
  });

  it("releases the wait on client abort without leaking a listener", async () => {
    const { app, listenerCount } = testApp();
    const id = newId();
    await create(app, id);
    const controller = new AbortController();
    const pending = call(app, {
      path: `/v1/memos/${id}/result?wait=600`,
      signal: controller.signal,
    });
    await Bun.sleep(10);
    expect(listenerCount()).toBe(1);
    controller.abort();
    const outcome = await Promise.race([
      pending.then(
        (res) => res.status,
        () => "aborted",
      ),
      Bun.sleep(1000).then(() => "stuck"),
    ]);
    expect(outcome).not.toBe("stuck");
    expect(listenerCount()).toBe(0);
  });
});
