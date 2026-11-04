import { describe, expect, it } from "bun:test";
import { legacyParkedMemo, seedMemo } from "../memo/test-support.js";
import { call, fakeHandlers, MAC, PHONE, testApp } from "./test-support.js";

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

const createText = (
  app: ReturnType<typeof testApp>["app"],
  json: Record<string, unknown> = {},
  headers = PHONE,
) =>
  call(app, {
    method: "POST",
    path: "/v1/memos/text",
    headers,
    json: {
      id: newId(),
      mode: "auto",
      startedAt: "2026-01-01T00:00:00.000Z",
      text: "kauf Milch",
      ...json,
    },
  });

describe("POST /v1/memos/text", () => {
  it("answers 202 with a transcribed memo, replays the same body and 409s another", async () => {
    const { app } = testApp({ handlers: fakeHandlers });
    const id = newId();
    const first = await createText(app, { id, text: "  kauf Milch " });
    expect(first.status).toBe(202);
    expect(await first.json()).toMatchObject({
      id,
      state: "transcribed",
      transcript: "kauf Milch",
      segmentCount: null,
      typed: true,
      device: "iphone",
    });
    expect((await createText(app, { id, text: "kauf Milch" })).status).toBe(202);
    expect((await createText(app, { id, text: "etwas anderes" })).status).toBe(409);
    expect((await createText(app, { id }, MAC)).status).toBe(409);
  });

  it("400s empty, whitespace-only and oversized text, a missing field and a bad mode", async () => {
    const { app } = testApp({ handlers: fakeHandlers });
    for (const bad of [
      { text: "" },
      { text: "   " },
      { text: "x".repeat(20_001) },
      { text: "😀".repeat(20_001) },
      { text: undefined },
      { mode: "nope" },
      { mode: undefined },
      { id: "../x" },
    ]) {
      const res = await createText(app, bad);
      expect([JSON.stringify(bad).slice(0, 40), res.status]).toEqual([
        JSON.stringify(bad).slice(0, 40),
        400,
      ]);
    }
  });

  it("counts code points: 20 000 emoji are accepted", async () => {
    const { app } = testApp({ handlers: fakeHandlers });
    expect((await createText(app, { text: "😀".repeat(20_000) })).status).toBe(202);
  });

  it("drives the memo to notified without ingest or transcribe rows", async () => {
    const { app } = testApp({ handlers: fakeHandlers });
    const id = newId();
    await createText(app, { id });
    const result = await call(app, { path: `/v1/memos/${id}/result?wait=5` });
    expect(await result.json()).toMatchObject({ state: "notified", transcript: "kauf Milch" });
    const detail = (await (await call(app, { path: `/v1/memos/${id}` })).json()) as {
      steps: { step: string }[];
      segmentCount: number;
    };
    expect(detail.steps.map((s) => s.step)).toEqual(["act", "summarize", "notify"]);
    expect(detail.segmentCount).toBe(0);
    expect(detail).toMatchObject({ typed: true });
  });

  it("409s GET /audio: a typed memo has no recording", async () => {
    const { app } = testApp({ handlers: fakeHandlers });
    const id = newId();
    await createText(app, { id });
    const res = await call(app, { path: `/v1/memos/${id}/audio` });
    expect(res.status).toBe(409);
    expect(await res.json()).toMatchObject({ error: "bad_state" });
  });

  it("requires a device token", async () => {
    const { app } = testApp();
    const res = await call(app, {
      method: "POST",
      path: "/v1/memos/text",
      headers: {},
      json: { id: newId(), mode: "auto", startedAt: "2026-01-01T00:00:00.000Z", text: "x" },
    });
    expect(res.status).toBe(401);
  });
});

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
      audioSeconds: null,
      transcript: null,
      route: null,
      destinationRef: null,
      replyText: null,
      summary: null,
    });
    const again = await create(app, id);
    expect(again.status).toBe(200);
  });

  it("400s a missing or unknown mode instead of defaulting to auto, and marks no recording typed", async () => {
    const { app } = testApp();
    const startedAt = "2026-01-01T00:00:00.000Z";
    for (const mode of [undefined, "nope"]) {
      const res = await call(app, {
        method: "POST",
        path: "/v1/memos",
        json: { id: newId(), mode, startedAt },
      });
      expect([mode, res.status]).toEqual([mode, 400]);
    }
    const recorded = await create(app);
    expect(await recorded.json()).not.toHaveProperty("typed");
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

  it("fails an act, then retries it with the data of act and later steps cleared", async () => {
    let broken = true;
    const { app } = testApp({
      handlers: {
        act: async () => {
          if (broken) throw new Error("hermes down");
          return {
            patch: {
              replyText: "Erledigt.",
              kind: "note",
              actions: ["web_search"],
            },
          };
        },
        summarize: async () => ({ patch: { summary: { headline: "H", detail: "", spoken: "S" } } }),
        notify: async () => ({}),
      },
    });
    const { id } = (await (await createText(app)).json()) as { id: string };
    const failed = await call(app, { path: `/v1/memos/${id}/result?wait=5` });
    expect(await failed.json()).toMatchObject({ state: "failed", failedStep: "act" });

    broken = false;
    const retry = await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/retry`,
      json: { from: "act" },
    });
    expect(retry.status).toBe(202);
    const done = await call(app, { path: `/v1/memos/${id}/result?wait=5` });
    expect(await done.json()).toMatchObject({
      state: "notified",
      kind: "note",
      actions: ["web_search"],
      summary: { headline: "H" },
    });
    const again = await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/retry`,
      json: { from: "act" },
    });
    expect(again.status).toBe(409);
  });

  it("400s a step outside the memo's pipeline, including the retired route", async () => {
    const { app, store } = testApp();
    const { id } = seedMemo(store, "transcribed");
    store.markStepFailed({ id, step: "act", error: "boom" });
    for (const from of ["route", "ingest"]) {
      const res = await call(app, {
        method: "POST",
        path: `/v1/memos/${id}/retry`,
        json: { from },
      });
      expect([from, res.status]).toEqual([from, 400]);
    }
    // a typed memo has no transcribe step to retry from
    const typed = await call(app, {
      method: "POST",
      path: "/v1/memos/text",
      json: { id: newId(), mode: "auto", startedAt: "2026-01-01T00:00:00.000Z", text: "x" },
    });
    expect(typed.status).toBe(202);
  });

  it("retries an old failed(route) memo from act", async () => {
    const ran: string[] = [];
    const { app, store, runner } = testApp({
      handlers: {
        act: async () => {
          ran.push("act");
          return {};
        },
        summarize: async () => {
          ran.push("summarize");
          return {};
        },
        notify: async () => {
          ran.push("notify");
          return {};
        },
      },
    });
    const { id } = seedMemo(store, "transcribed");
    store.markStepFailed({ id, step: "route", error: "old failure" });
    expect(store.getMemo(id)).toMatchObject({ state: "failed", failedStep: "route" });

    // failed at route: notify comes after the failure, so it cannot be retried from
    const wrong = await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/retry`,
      json: { from: "notify" },
    });
    expect(wrong.status).toBe(400);

    const res = await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/retry`,
      json: { from: "act" },
    });
    expect(res.status).toBe(202);
    await runner.idle();
    expect(store.getMemo(id)?.state).toBe("notified");
    expect(ran).toEqual(["act", "summarize", "notify"]);
  });

  it("ends a memo whose summarize failed as notified, and retries its summarize", async () => {
    let broken = true;
    const { app } = testApp({
      handlers: {
        act: async () => ({ patch: { replyText: "Erledigt.", hermesHeadline: "Hermes says" } }),
        summarize: async () => {
          if (broken) throw new Error("402 payment required");
          return { patch: { summary: { headline: "H", detail: "D", spoken: "S" } } };
        },
        notify: async () => ({}),
      },
    });
    const created = await createText(app);
    const { id } = (await created.json()) as { id: string };
    const res = await call(app, { path: `/v1/memos/${id}/result?wait=5` });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toMatchObject({ state: "notified", failedStep: null, error: null, summary: null });
    // The wire has no hermes headline: clients show the transcript.
    expect(JSON.stringify(body)).not.toContain("Hermes says");
    const detail = await call(app, { path: `/v1/memos/${id}` });
    expect(await detail.json()).toMatchObject({
      steps: expect.arrayContaining([
        expect.objectContaining({
          step: "summarize",
          status: "failed",
          error: "402 payment required",
        }),
      ]),
    });

    broken = false;
    const retry = await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/retry`,
      json: { from: "summarize" },
    });
    expect(retry.status).toBe(202);
    expect(await retry.json()).toMatchObject({ state: "acted" });
    const done = await call(app, { path: `/v1/memos/${id}/result?wait=5` });
    expect(await done.json()).toMatchObject({ state: "notified", summary: { headline: "H" } });

    // nothing failed any more: a second retry is a conflict
    const again = await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/retry`,
      json: { from: "summarize" },
    });
    expect(again.status).toBe(409);
  });

  it("400s a missing from instead of defaulting it", async () => {
    const { app } = testApp();
    const res = await call(app, {
      method: "POST",
      path: `/v1/memos/${newId()}/retry`,
      json: {},
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toMatchObject({ error: "bad_request" });
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

  it("returns the pipeline outcome with the finished memo", async () => {
    const { app, store } = testApp();
    const id = newId();
    await create(app, id);
    store.markReceived({ id, segmentCount: 1 });
    const summary = { headline: "h", detail: "d", spoken: "s" };
    store.completeStep({
      id,
      step: "transcribe",
      from: "received",
      to: "transcribed",
      patch: {
        transcript: "hello",
        audioSeconds: 2.5,
        destinationRef: "session-1",
        replyText: "done",
        summary,
        kind: "note",
        actions: ["web_search", "terminal"],
      },
    });
    store.transition({ id, from: "transcribed", to: "needs_route" });
    const res = await call(app, { path: `/v1/memos/${id}/result` });
    expect(await res.json()).toMatchObject({
      transcript: "hello",
      audioSeconds: 2.5,
      destinationRef: "session-1",
      replyText: "done",
      summary,
      kind: "note",
      actions: ["web_search", "terminal"],
    });
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

describe("removed routes", () => {
  it("404s POST /memos/:id/route and GET /herd", async () => {
    const { app, store } = testApp();
    const { id } = seedMemo(store, "notified");
    const route = await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/route`,
      json: { destination: "hermes" },
    });
    expect(route.status).toBe(404);
    expect((await call(app, { path: "/v1/herd" })).status).toBe(404);
  });
});

describe("memo kind and actions on the wire", () => {
  it("omits kind and actions while empty and carries them once set", async () => {
    const { app, store } = testApp();
    const { id } = seedMemo(store, "transcribed");
    const plain = (await (await call(app, { path: `/v1/memos/${id}` })).json()) as Record<
      string,
      unknown
    >;
    expect(plain).not.toHaveProperty("kind");
    expect(plain).not.toHaveProperty("actions");

    store.markStepStarted({ id, step: "act" });
    store.completeStep({
      id,
      step: "act",
      from: "transcribed",
      to: "acted",
      patch: { kind: "note", actions: ["web_search", "terminal"] },
    });
    const set = (await (await call(app, { path: `/v1/memos/${id}` })).json()) as Record<
      string,
      unknown
    >;
    expect(set).toMatchObject({ kind: "note", actions: ["web_search", "terminal"] });
    expect(set).not.toHaveProperty("routeReason");
    expect(set).not.toHaveProperty("routeSuggestion");
    const listed = (await (await call(app, { path: "/v1/memos" })).json()) as {
      items: Record<string, unknown>[];
    };
    expect(listed.items[0]).toMatchObject({ kind: "note" });
  });

  it("lists a legacy needs_route memo as a plain item, with no pinned section", async () => {
    const { app, store } = testApp();
    const id = legacyParkedMemo(store);
    const body = (await (await call(app, { path: "/v1/memos" })).json()) as {
      items: { id: string; state: string }[];
    };
    expect(body).not.toHaveProperty("pinned");
    expect(body.items).toEqual([expect.objectContaining({ id, state: "needs_route" })]);
  });
});

describe("GET /v1/memos filters", () => {
  const list = async (app: ReturnType<typeof testApp>["app"], query = "") => {
    const res = await call(app, { path: `/v1/memos${query}` });
    return { res, body: (await res.json()) as { items: { id: string }[] } };
  };

  /** Moves a transcribed memo through act with the given kind and transcript. */
  const acted = (
    store: ReturnType<typeof testApp>["store"],
    patch: { kind?: string; transcript?: string },
  ) => {
    const { id } = seedMemo(store, "transcribed");
    if (patch.transcript !== undefined) {
      store.completeStep({
        id,
        step: "transcribe",
        from: "transcribed",
        to: "transcribed",
        patch: { transcript: patch.transcript },
      });
    }
    store.markStepStarted({ id, step: "act" });
    store.completeStep({
      id,
      step: "act",
      from: "transcribed",
      to: "acted",
      patch: patch.kind === undefined ? {} : { kind: patch.kind },
    });
    return id;
  };

  it("searches and filters by kind and state over HTTP", async () => {
    const { app, store } = testApp();
    const hit = acted(store, { kind: "note", transcript: "Trag den Termin in den Kalender ein" });
    acted(store, { kind: "task", transcript: "Kalender anderes" });
    seedMemo(store, "notified");

    const found = await list(app, "?q=Kalend&kind=note&state=acted");
    expect(found.body.items.map((m) => m.id)).toEqual([hit]);
    expect((await list(app, "?q=kalender")).body.items).toHaveLength(2);
    expect((await list(app, "?state=notified")).body.items).toHaveLength(1);
  });

  it("matches the kind exactly after normalising it", async () => {
    const { app, store } = testApp();
    const note = acted(store, { kind: "note" });
    acted(store, { kind: "notebook" });
    const untyped = acted(store, {});

    expect((await list(app, "?kind=note")).body.items.map((m) => m.id)).toEqual([note]);
    expect((await list(app, "?kind=%20Note%20")).body.items.map((m) => m.id)).toEqual([note]);
    expect((await list(app, "?kind=NOTE")).body.items.map((m) => m.id)).toEqual([note]);
    expect((await list(app, "?kind=nothing")).body.items).toEqual([]);
    expect((await list(app, "?kind=")).body.items).toEqual([]);
    expect((await list(app, "?kind=%20%20")).body.items).toEqual([]);
    expect((await list(app)).body.items.map((m) => m.id)).toContain(untyped);
  });

  it("keeps only the memos of a conversation with thread=true, not a memo alone in its session", async () => {
    const { app, store } = testApp();
    const inSession = (session: string) => {
      const { id } = seedMemo(store, "transcribed");
      store.markStepStarted({ id, step: "act" });
      store.completeStep({
        id,
        step: "act",
        from: "transcribed",
        to: "acted",
        patch: { thread: { id: session, kind: "hermes", title: "t" } },
      });
      return id;
    };
    const alone = inSession("alone");
    const first = inSession("talk");
    const second = inSession("talk");
    const plain = seedMemo(store, "notified").id;

    expect((await list(app, "?thread=true")).body.items.map((m) => m.id)).toEqual([second, first]);
    expect((await list(app)).body.items.map((m) => m.id).toSorted()).toEqual(
      [alone, first, second, plain].toSorted(),
    );
  });

  it("answers 400 for an unknown state, a bad thread value and an over-long q", async () => {
    const { app } = testApp();
    for (const query of [
      "?state=nope",
      "?state=",
      "?thread=yes",
      "?thread=1",
      `?q=${"x".repeat(201)}`,
    ]) {
      const { res } = await list(app, query);
      expect([query, res.status]).toEqual([query, 400]);
    }
  });

  it("ignores the removed route param", async () => {
    const { app, store } = testApp();
    const id = seedMemo(store, "notified").id;
    const { res, body } = await list(app, "?route=nope");
    expect(res.status).toBe(200);
    expect(body.items.map((m) => m.id)).toEqual([id]);
  });
});
