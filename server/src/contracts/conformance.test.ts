import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { call, MAC, PHONE, testApp } from "../http/test-support.js";
import type { StepHandler } from "../memo/runner.js";
import type { HandlerStep } from "../memo/memo.js";
import {
  buildAlert,
  buildLiveActivityEnd,
  buildLiveActivityUpdate,
  buildNeedsRouteAlert,
} from "../notify/payloads.js";
import { createReplyAssets } from "../memo/reply-assets.js";
import { fakeAssetStore, fakeDiagramRenderer, fakeHerd } from "../ports/fakes.js";
import { loadContracts, MANIFEST_FILE, violations } from "./check.js";
import { keyDifferences, sseFrames } from "./conformance-support.js";
import { Manifest, routeKey } from "./manifest.js";

// The real app, driven through its key flows: every JSON body it answers must satisfy the schema the
// manifest names for that route and status, and carry exactly the keys of that schema's fixtures.
// The reverse direction: every request fixture must be accepted by the server.

const ROOT = join(import.meta.dir, "../../../contracts");
const contracts = loadContracts(ROOT);
const manifest = Manifest.parse(JSON.parse(readFileSync(join(ROOT, MANIFEST_FILE), "utf8")));

const fixturesOf = (schema: string) => contracts.fixtures.filter((f) => f.schema === schema);
const fixture = (stem: string) => {
  const found = contracts.fixtures.find((f) => f.stem === stem);
  if (!found) throw new Error(`no fixture ${stem}`);
  return found;
};

/** Schema properties that are omitted rather than null: a body or fixture may lack them. */
const OPTIONAL_KEYS = [
  "routeReason",
  "routeSuggestion",
  "typed",
  "threadId",
  "deletedAt",
  "purgeAt",
  "replyBlocks",
];

/** Validates `value` against `schema` and compares its keys with each fixture (default: all of them). */
function conforms(params: { schema: string; value: unknown; fixtures?: string[] }) {
  const { schema, value } = params;
  const validate = contracts.validators.get(schema);
  if (!validate) throw new Error(`no schema ${schema}`);
  expect([schema, ...violations(validate, value)]).toEqual([schema]);
  const against = params.fixtures?.map(fixture) ?? fixturesOf(schema);
  expect(against.length).toBeGreaterThan(0);
  for (const f of against) {
    expect([
      f.stem,
      ...keyDifferences({ live: value, fixture: f.value, optionalKeys: OPTIONAL_KEYS }),
    ]).toEqual([f.stem]);
  }
  return value;
}

/** The manifest's schema for `route` at the response's status; reads and checks the JSON body. */
async function conformingBody(params: { route: string; res: Response; fixtures?: string[] }) {
  const { route, res } = params;
  const entry = manifest.routes.find((r) => routeKey(r) === route);
  const body = entry?.responses[String(res.status)];
  if (!body) throw new Error(`${route} has no ${res.status} in the manifest`);
  if (!("schema" in body)) throw new Error(`${route} ${res.status} is not JSON in the manifest`);
  expect(res.headers.get("content-type")).toContain(body.mediaType);
  return conforms({
    schema: body.schema,
    value: await res.json(),
    ...(params.fixtures && { fixtures: params.fixtures }),
  }) as Record<string, unknown>;
}

const SUMMARY = { headline: "Plan steht", detail: "Release am Donnerstag.", spoken: "Plan steht." };
const handlers = (overrides: Partial<Record<HandlerStep, StepHandler>> = {}) => ({
  transcribe: async () => ({
    patch: { transcript: "Hallo Welt", audioSeconds: 12.5 },
    usage: { audioSeconds: 12.5 },
    costUsd: 0.001,
  }),
  route: async () => ({ patch: { route: "hermes" } }),
  act: async () => ({
    patch: { destinationRef: "iris-session", replyText: "Notiert." },
    usage: { inputTokens: 10, outputTokens: 5, totalTokens: 15 },
    costUsd: 0.01,
  }),
  summarize: async () => ({ patch: { summary: SUMMARY }, costUsd: 0.002 }),
  notify: async () => ({}),
  ...overrides,
});

type App = ReturnType<typeof testApp>["app"];
const create = (app: App, id: string, mode = "hermes", headers = PHONE) =>
  call(app, {
    method: "POST",
    path: "/v1/memos",
    headers,
    json: { id, mode, startedAt: "2026-03-14T09:20:41.000Z" },
  });
const upload = (app: App, id: string, n: number) =>
  call(app, {
    method: "PUT",
    path: `/v1/memos/${id}/segments/${n}`,
    headers: { ...PHONE, "content-type": "audio/mp4" },
    body: new Uint8Array(8).fill(n + 1),
  });
const complete = (app: App, id: string, segmentCount: number) =>
  call(app, { method: "POST", path: `/v1/memos/${id}/complete`, json: { segmentCount } });

/** create → upload → complete; resolves once the pipeline reached a result-ready state. */
async function record(app: App, segments = 2) {
  const id = crypto.randomUUID();
  await create(app, id);
  for (let n = 0; n < segments; n++) await upload(app, id, n);
  await complete(app, id, segments);
  await call(app, { path: `/v1/memos/${id}/result?wait=5` });
  return id;
}

const park = (reason: string, destination: string | null) => ({
  outcome: "needs_route" as const,
  patch: {
    routeDecision: {
      source: "decide" as const,
      destination,
      tab: null,
      confidence: null,
      model: null,
      costUsd: null,
      reason,
      outcome: "needs_route" as const,
    },
  },
});

describe("flows: every response conforms", () => {
  it("a typed memo: create answers 202 and reaches notified, a replay and a different body conform", async () => {
    const { app } = testApp({ handlers: handlers() });
    const id = crypto.randomUUID();
    const body = { id, mode: "hermes", startedAt: "2026-03-14T09:45:12.000Z", text: "Hallo Welt" };
    const text = (json: unknown) => call(app, { method: "POST", path: "/v1/memos/text", json });

    const created = await text(body);
    expect(created.status).toBe(202);
    const memo = await conformingBody({
      route: "POST /v1/memos/text",
      res: created,
      fixtures: ["memos.text.response"],
    });
    expect(memo).toMatchObject({
      state: "transcribed",
      segmentCount: null,
      typed: true,
      transcript: "Hallo Welt",
    });

    const replay = await text(body);
    expect(replay.status).toBe(202);
    await conformingBody({ route: "POST /v1/memos/text", res: replay });

    const conflict = await text({ ...body, text: "Anderer Text" });
    expect(conflict.status).toBe(409);
    await conformingBody({ route: "POST /v1/memos/text", res: conflict });

    const empty = await text({ ...body, id: crypto.randomUUID(), text: "   " });
    expect(empty.status).toBe(400);
    await conformingBody({ route: "POST /v1/memos/text", res: empty });

    await call(app, { path: `/v1/memos/${id}/result?wait=5` });
    const detail = await call(app, { path: `/v1/memos/${id}` });
    const typedDetail = await conformingBody({
      route: "GET /v1/memos/:id",
      res: detail,
      fixtures: ["memos.detail.response.typed"],
    });
    expect(typedDetail).toMatchObject({ typed: true, segmentCount: 0 });
    expect((typedDetail["steps"] as { step: string }[]).map((s) => s.step)).toEqual([
      "route",
      "act",
      "summarize",
      "notify",
    ]);
  });

  it("a chat memo carries its threadId on the detail and the list", async () => {
    const { app } = testApp({
      handlers: handlers({
        act: async ({ memo }) => ({
          patch: {
            destinationRef: memo.id,
            replyText: "Ein Mutex hat einen Halter.",
            thread: { id: memo.id, kind: "chat", title: "Mutex gegen Semaphor" },
          },
        }),
      }),
    });
    const id = crypto.randomUUID();
    const created = await create(app, id, "chat");
    expect(created.status).toBe(201);
    await conformingBody({ route: "POST /v1/memos", res: created });
    for (let n = 0; n < 4; n++) await upload(app, id, n);
    expect((await complete(app, id, 4)).status).toBe(202);
    await call(app, { path: `/v1/memos/${id}/result?wait=5` });

    const detail = await conformingBody({
      route: "GET /v1/memos/:id",
      res: await call(app, { path: `/v1/memos/${id}` }),
      fixtures: ["memos.detail.response.chat"],
    });
    expect(detail).toMatchObject({ mode: "chat", state: "notified", threadId: id });
    const list = await call(app, { path: "/v1/memos" });
    const items = ((await list.json()) as { items: { id: string; threadId?: string }[] }).items;
    expect(items.find((m) => m.id === id)?.threadId).toBe(id);
  });

  it("a transcribe memo ends notified with the transcript, no route, reply or summary, and two steps", async () => {
    const { app } = testApp({
      handlers: handlers({
        route: async () => ({}),
        act: async () => ({}),
        summarize: async () => ({}),
      }),
    });
    const id = crypto.randomUUID();
    const created = await create(app, id, "transcribe");
    expect(created.status).toBe(201);
    await conformingBody({
      route: "POST /v1/memos",
      res: created,
      fixtures: ["memos.create.response"],
    });
    for (let n = 0; n < 2; n++) await upload(app, id, n);
    expect((await complete(app, id, 2)).status).toBe(202);
    await call(app, { path: `/v1/memos/${id}/result?wait=5` });

    const detail = await conformingBody({
      route: "GET /v1/memos/:id",
      res: await call(app, { path: `/v1/memos/${id}` }),
      fixtures: ["memos.detail.response.transcribe"],
    });
    expect(detail).toMatchObject({
      mode: "transcribe",
      state: "notified",
      transcript: "Hallo Welt",
      route: null,
      replyText: null,
      summary: null,
    });
    expect((detail["steps"] as { step: string }[]).map((s) => s.step)).toEqual([
      "transcribe",
      "notify",
    ]);

    const text = await call(app, {
      method: "POST",
      path: "/v1/memos/text",
      json: {
        id: crypto.randomUUID(),
        mode: "transcribe",
        startedAt: "2026-03-14T09:20:41.000Z",
        text: "So wie getippt.",
      },
    });
    expect(text.status).toBe(202);
    await conformingBody({ route: "POST /v1/memos/text", res: text });
  });

  it("create, upload, complete, result, detail, list, activity token and media on a notified memo", async () => {
    const { app } = testApp({ handlers: handlers(), maxSegmentBytes: 1024 });
    const id = crypto.randomUUID();

    const created = await create(app, id);
    expect(created.status).toBe(201);
    await conformingBody({ route: "POST /v1/memos", res: created });
    const again = await create(app, id);
    expect(again.status).toBe(200);
    await conformingBody({ route: "POST /v1/memos", res: again });

    const pending = await call(app, { path: `/v1/memos/${id}/result` });
    expect(pending.status).toBe(202);
    expect(
      (await conformingBody({ route: "GET /v1/memos/:id/result", res: pending }))["state"],
    ).toBe("receiving");

    const put = await upload(app, id, 0);
    expect(put.status).toBe(200);
    expect(await put.text()).toBe("");
    const missing = await complete(app, id, 2);
    expect(missing.status).toBe(422);
    expect(
      await conformingBody({ route: "POST /v1/memos/:id/complete", res: missing }),
    ).toMatchObject({ error: "missing_segments", missing: [1] });

    await upload(app, id, 1);
    const accepted = await complete(app, id, 2);
    expect(accepted.status).toBe(202);
    await conformingBody({ route: "POST /v1/memos/:id/complete", res: accepted });

    const result = await call(app, { path: `/v1/memos/${id}/result?wait=5` });
    expect(result.status).toBe(200);
    expect(await conformingBody({ route: "GET /v1/memos/:id/result", res: result })).toMatchObject({
      state: "notified",
      summary: SUMMARY,
    });

    const detail = await call(app, { path: `/v1/memos/${id}` });
    const body = await conformingBody({ route: "GET /v1/memos/:id", res: detail });
    expect(body["steps"]).toHaveLength(5);

    const list = await call(app, { path: "/v1/memos?limit=1" });
    await conformingBody({ route: "GET /v1/memos", res: list });
    const empty = testApp();
    const emptyList = await call(empty.app, { path: "/v1/memos" });
    await conformingBody({ route: "GET /v1/memos", res: emptyList });

    const token = await call(app, {
      method: "PUT",
      path: `/v1/memos/${id}/activity-token`,
      json: fixture("memos.activity-token.request").value,
    });
    expect(token.status).toBe(204);
    expect(await token.text()).toBe("");

    const audio = await call(app, { path: `/v1/memos/${id}/audio` });
    expect([audio.status, audio.headers.get("content-type")]).toEqual([200, "audio/mp4"]);
    const ranged = await call(app, {
      path: `/v1/memos/${id}/audio`,
      headers: { ...PHONE, range: "bytes=0-9" },
    });
    expect([ranged.status, ranged.headers.get("content-type")]).toEqual([206, "audio/mp4"]);
    const speech = await call(app, { path: `/v1/memos/${id}/speech` });
    expect([speech.status, speech.headers.get("content-type")]).toEqual([200, "audio/mpeg"]);
  });

  it("a failed memo: result, detail and the retry round trip", async () => {
    const failing = handlers({
      transcribe: async () => {
        throw new Error("audio door transcription failed: 502");
      },
    });
    const { app } = testApp({ handlers: failing });
    const id = await record(app);

    const result = await call(app, { path: `/v1/memos/${id}/result` });
    expect(await conformingBody({ route: "GET /v1/memos/:id/result", res: result })).toMatchObject({
      state: "failed",
      failedStep: "transcribe",
    });
    const detail = await call(app, { path: `/v1/memos/${id}` });
    const body = await conformingBody({ route: "GET /v1/memos/:id", res: detail });
    expect((body["steps"] as unknown[])[0]).toMatchObject({ step: "transcribe", status: "failed" });

    const retry = await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/retry`,
      json: fixture("memos.retry.request").value,
    });
    expect(retry.status).toBe(202);
    await conformingBody({ route: "POST /v1/memos/:id/retry", res: retry });
  });

  it("a memo parked in needs_route is a ready result and carries why", async () => {
    const { app } = testApp({
      handlers: handlers({ route: async () => park("low confidence (0.62)", "hermes") }),
    });
    const id = await record(app);
    const result = await call(app, { path: `/v1/memos/${id}/result` });
    expect(result.status).toBe(200);
    expect(await conformingBody({ route: "GET /v1/memos/:id/result", res: result })).toMatchObject({
      state: "needs_route",
      route: null,
      routeReason: "low confidence (0.62)",
      routeSuggestion: "hermes",
    });
    const detail = await call(app, { path: `/v1/memos/${id}` });
    await conformingBody({ route: "GET /v1/memos/:id", res: detail });
  });

  it("flags, delete and restore answer the memo and the error shapes", async () => {
    const { app } = testApp({ handlers: handlers() });
    const id = await record(app);
    const patch = (json: unknown, target = id) =>
      call(app, { method: "PATCH", path: `/v1/memos/${target}`, json });

    const flagged = await patch({ done: true, favorite: true, archived: true });
    expect(flagged.status).toBe(200);
    expect(await conformingBody({ route: "PATCH /v1/memos/:id", res: flagged })).toMatchObject({
      done: true,
      favorite: true,
      archived: true,
    });
    for (const body of [{}, { done: "yes" }, { starred: true }]) {
      const bad = await patch(body);
      expect([body, bad.status]).toEqual([body, 400]);
      await conformingBody({ route: "PATCH /v1/memos/:id", res: bad });
    }
    const unknown = await patch({ done: true }, crypto.randomUUID());
    expect(unknown.status).toBe(404);
    await conformingBody({ route: "PATCH /v1/memos/:id", res: unknown });

    const deleted = await call(app, { method: "DELETE", path: `/v1/memos/${id}` });
    expect(deleted.status).toBe(200);
    expect(await conformingBody({ route: "DELETE /v1/memos/:id", res: deleted })).toHaveProperty(
      "purgeAt",
    );
    const detail = await call(app, { path: `/v1/memos/${id}` });
    await conformingBody({ route: "GET /v1/memos/:id", res: detail });
    const locked = await patch({ done: false });
    expect(locked.status).toBe(409);
    await conformingBody({ route: "PATCH /v1/memos/:id", res: locked });

    const restored = await call(app, { method: "POST", path: `/v1/memos/${id}/restore` });
    expect(restored.status).toBe(200);
    expect(
      await conformingBody({ route: "POST /v1/memos/:id/restore", res: restored }),
    ).not.toHaveProperty("deletedAt");
    const again = await call(app, { method: "POST", path: `/v1/memos/${id}/restore` });
    expect(again.status).toBe(409);
    await conformingBody({ route: "POST /v1/memos/:id/restore", res: again });
    const gone = await call(app, {
      method: "DELETE",
      path: `/v1/memos/${crypto.randomUUID()}`,
    });
    expect(gone.status).toBe(404);
    await conformingBody({ route: "DELETE /v1/memos/:id", res: gone });
  });

  it("answer, correction and the route errors", async () => {
    const parks = handlers({
      route: async () => ({
        outcome: "needs_route",
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
      }),
    });
    const { app } = testApp({ handlers: parks });
    const id = await record(app);
    const path = `/v1/memos/${id}/route`;
    const post = (json: unknown) => call(app, { method: "POST", path, json });

    const unavailable = await post(fixture("memos.route.request.herdr").value);
    expect(unavailable.status).toBe(400);
    await conformingBody({ route: "POST /v1/memos/:id/route", res: unavailable });
    const missing = await call(app, {
      method: "POST",
      path: `/v1/memos/${crypto.randomUUID()}/route`,
      json: fixture("memos.route.request").value,
    });
    expect(missing.status).toBe(404);
    await conformingBody({ route: "POST /v1/memos/:id/route", res: missing });

    const answered = await post(fixture("memos.route.request").value);
    expect(answered.status).toBe(202);
    expect(
      await conformingBody({
        route: "POST /v1/memos/:id/route",
        res: answered,
        fixtures: ["memos.route.response"],
      }),
    ).toMatchObject({ state: "routed", route: "hermes" });

    // The fake route handler parks again on the next pass only after a retry; here the memo runs on to notified.
    await call(app, { path: `/v1/memos/${id}/result?wait=5` });
    const second = await post(fixture("memos.route.request").value);
    expect(second.status).toBe(200);
    await conformingBody({ route: "POST /v1/memos/:id/route", res: second });
  });

  it("devices, herd, health and whoami", async () => {
    const { app } = testApp({ handlers: handlers() });
    for (const f of contracts.fixtures.filter((x) => x.schema === "devices.register.request")) {
      const res = await call(app, { method: "POST", path: "/v1/devices/register", json: f.value });
      expect([f.stem, res.status]).toEqual([f.stem, 200]);
      await conformingBody({ route: "POST /v1/devices/register", res });
    }

    const herd = await call(app, { path: "/v1/herd" });
    await conformingBody({ route: "GET /v1/herd", res: herd });
    const noTabs = testApp({ herd: fakeHerd({ tabs: [] }) });
    const empty = await call(noTabs.app, { path: "/v1/herd" });
    expect(
      ((await conformingBody({ route: "GET /v1/herd", res: empty })) as { tabs: [] }).tabs,
    ).toEqual([]);

    const stats = await call(app, { path: "/v1/stats" });
    await conformingBody({ route: "GET /v1/stats", res: stats });
    const badDays = await call(app, { path: "/v1/stats?days=0" });
    expect(badDays.status).toBe(400);
    await conformingBody({ route: "GET /v1/stats", res: badDays });

    const health = await app.handle(new Request("http://iris.test/health"));
    expect(await conformingBody({ route: "GET /health", res: health })).toMatchObject({
      status: "ok",
    });
    const whoami = await call(app, { path: "/v1/whoami", headers: MAC });
    expect(await conformingBody({ route: "GET /v1/whoami", res: whoami })).toEqual({
      device: "macbook",
    });
  });
});

/** An `act` that ran in a chat thread. */
const actInThread = async () => ({
  patch: {
    destinationRef: "iris-session",
    replyText: "Notiert.",
    thread: { id: "iris-session", kind: "chat" as const, title: "Hallo Welt" },
  },
});

describe("flows: threads conform", () => {
  it("list, detail and an unknown thread", async () => {
    const { app } = testApp({ handlers: handlers({ act: actInThread }) });
    await record(app);

    const list = await call(app, { path: "/v1/threads" });
    const listed = await conformingBody({ route: "GET /v1/threads", res: list });
    expect(listed).toMatchObject({ items: [{ id: "iris-session", kind: "chat" }] });

    const detail = await call(app, { path: "/v1/threads/iris-session" });
    expect(await conformingBody({ route: "GET /v1/threads/:id", res: detail })).toMatchObject({
      messages: [
        { role: "user", content: "Hallo Welt" },
        { role: "assistant", content: "Notiert." },
      ],
    });

    const missing = await call(app, { path: "/v1/threads/nope" });
    expect(missing.status).toBe(404);
    expect(await conformingBody({ route: "GET /v1/threads/:id", res: missing })).toMatchObject({
      error: "not_found",
    });
  });
});

describe("flows: every error shape conforms", () => {
  it("a reply with a Mermaid block carries replyBlocks on the detail and the list, and the assets route serves them", async () => {
    const assets = fakeAssetStore();
    const { app, store, clock } = testApp({
      assets,
      handlers: (s) =>
        handlers({
          act: async ({ memo }) => {
            const replyText = "Ablauf:\n\n```mermaid\nflowchart LR\n  A --> B\n```";
            await createReplyAssets({ store: s, assets, renderer: fakeDiagramRenderer() }).sync({
              memoId: memo.id,
              replyText,
            });
            return { patch: { destinationRef: memo.id, replyText } };
          },
        }),
    });
    const id = await record(app);

    const detail = await conformingBody({
      route: "GET /v1/memos/:id",
      res: await call(app, { path: `/v1/memos/${id}` }),
      fixtures: ["memos.detail.response.assets"],
    });
    const [block] = detail["replyBlocks"] as { svg: { light: string }; png: { dark: string } }[];
    const list = await call(app, { path: "/v1/memos" });
    const items = ((await list.json()) as { items: { id: string; replyBlocks?: unknown[] }[] })
      .items;
    expect(items.find((m) => m.id === id)?.replyBlocks).toHaveLength(1);

    const svg = await call(app, { path: `/v1/memos/${id}/assets/${block?.svg.light}` });
    expect([svg.status, svg.headers.get("content-type")]).toEqual([200, "image/svg+xml"]);
    const png = await call(app, { path: `/v1/memos/${id}/assets/${block?.png.dark}` });
    expect([png.status, png.headers.get("content-type")]).toEqual([200, "image/png"]);

    const missing = await call(app, { path: `/v1/memos/${id}/assets/nope` });
    expect(missing.status).toBe(404);
    expect(
      await conformingBody({ route: "GET /v1/memos/:id/assets/:assetId", res: missing }),
    ).toMatchObject({ error: "not_found" });

    store.markDeleted({ id, at: clock.now().toISOString() });
    const gone = await call(app, { path: `/v1/memos/${id}/assets/${block?.png.dark}` });
    expect(gone.status).toBe(409);
    await conformingBody({ route: "GET /v1/memos/:id/assets/:assetId", res: gone });
  });

  it("404, 409, 400, 413, 422 and 503 carry the manifest's error schemas", async () => {
    const { app } = testApp({ handlers: handlers(), maxSegmentBytes: 4, herd: false });
    const unknown = crypto.randomUUID();

    const notFound = await call(app, { path: `/v1/memos/${unknown}` });
    expect(notFound.status).toBe(404);
    expect(await conformingBody({ route: "GET /v1/memos/:id", res: notFound })).toMatchObject({
      error: "not_found",
    });

    const id = crypto.randomUUID();
    await create(app, id);
    const conflict = await create(app, id, "hermes", MAC);
    expect(conflict.status).toBe(409);
    expect(await conformingBody({ route: "POST /v1/memos", res: conflict })).toMatchObject({
      error: "conflict",
    });

    const badState = await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/retry`,
      json: { from: "transcribe" },
    });
    expect(badState.status).toBe(409);
    expect(
      await conformingBody({ route: "POST /v1/memos/:id/retry", res: badState }),
    ).toMatchObject({
      error: "bad_state",
    });

    const badRequest = await create(app, crypto.randomUUID(), "nonsense");
    expect(badRequest.status).toBe(400);
    expect(await conformingBody({ route: "POST /v1/memos", res: badRequest })).toMatchObject({
      error: "bad_request",
    });

    const tooLarge = await call(app, {
      method: "PUT",
      path: `/v1/memos/${id}/segments/0`,
      headers: { ...PHONE, "content-type": "audio/mp4" },
      body: new Uint8Array(16),
    });
    expect(tooLarge.status).toBe(413);
    expect(
      await conformingBody({ route: "PUT /v1/memos/:id/segments/:n", res: tooLarge }),
    ).toMatchObject({ error: "too_large", maxBytes: 4 });

    const unavailable = await call(app, { path: "/v1/herd" });
    expect(unavailable.status).toBe(503);
    expect(await conformingBody({ route: "GET /v1/herd", res: unavailable })).toMatchObject({
      error: "unavailable",
    });
  });

  it("a missing or wrong token is plain text, never JSON", async () => {
    const { app } = testApp();
    const { status, body } = manifest.unauthorized;
    for (const headers of [{}, { authorization: "Bearer nope" }]) {
      const res = await call(app, { path: "/v1/whoami", headers });
      expect(res.status).toBe(status);
      expect(await res.text()).toBe(body);
    }
    const health = await app.handle(new Request("http://iris.test/health"));
    expect(health.status).toBe(200);
  });
});

describe("GET /v1/events", () => {
  it("streams frames whose data satisfies the manifest's event schemas", async () => {
    const { app } = testApp({ handlers: handlers(), sseKeepaliveMs: 20 });
    const stream = await call(app, { path: "/v1/events" });
    expect(stream.headers.get("content-type")).toContain("text/event-stream");
    const reader = (stream.body as ReadableStream<Uint8Array>).getReader();

    await record(app);

    const decoder = new TextDecoder();
    let text = "";
    const deadline = Date.now() + 3000;
    while (!text.includes("event: memo.done") && Date.now() < deadline) {
      const part = await Promise.race([reader.read(), Bun.sleep(100).then(() => null)]);
      if (part?.value) text += decoder.decode(part.value, { stream: true });
    }
    await reader.cancel();

    const events = manifest.routes.find((r) => routeKey(r) === "GET /v1/events")?.events ?? [];
    const frames = sseFrames(text);
    expect(new Set(frames.map((f) => f.event))).toEqual(new Set(events.map((e) => e.name)));
    for (const frame of frames) {
      const schema = events.find((e) => e.name === frame.event)?.schema ?? "";
      conforms({ schema, value: JSON.parse(frame.data) });
    }
    expect(frames[0]).toEqual({ event: "ready", data: "{}" });
  });
});

const memo = (patch: Record<string, unknown>) => ({
  ...(fixture("memos.result.response").value as object),
  ...patch,
});
const live = (build: () => { payload: Record<string, unknown> }) =>
  (build().payload["aps"] as Record<string, unknown>)["content-state"];

describe("push payloads", () => {
  const NOW = new Date("2026-03-14T09:21:19.000Z");
  it("builders emit exactly the content-state fixtures", () => {
    const base = memo({}) as never;
    const summary = (fixture("memos.result.response").value as { summary: never }).summary;
    const cases: Array<[string, unknown]> = [
      [
        "liveactivity.content-state",
        live(() => buildLiveActivityEnd({ topic: "t", memo: base, summary, now: NOW })),
      ],
      [
        "liveactivity.content-state.processing",
        live(() =>
          buildLiveActivityUpdate({
            topic: "t",
            memo: memo({ state: "received", route: null, summary: null, replyText: null }) as never,
            now: NOW,
          }),
        ),
      ],
      [
        "liveactivity.content-state.routed",
        live(() =>
          buildLiveActivityUpdate({
            topic: "t",
            memo: memo({ state: "routed", summary: null, replyText: null }) as never,
            now: NOW,
          }),
        ),
      ],
      [
        "liveactivity.content-state.needs-route",
        live(() =>
          buildLiveActivityUpdate({
            topic: "t",
            memo: memo({
              state: "needs_route",
              route: null,
              summary: null,
              replyText: null,
            }) as never,
            now: NOW,
          }),
        ),
      ],
      [
        "liveactivity.content-state.failed",
        live(() =>
          buildLiveActivityUpdate({
            topic: "t",
            memo: memo({ state: "failed", summary: null, replyText: null }) as never,
            now: NOW,
          }),
        ),
      ],
    ];
    for (const [stem, state] of cases) {
      conforms({ schema: "liveactivity.content-state", value: state, fixtures: [stem] });
    }
  });

  it("builds the needs-route alert that matches its fixture", () => {
    conforms({
      schema: "push.alert",
      value: buildNeedsRouteAlert({
        topic: "t",
        memo: memo({}) as never,
        reason: "journal not available",
      }).payload,
      fixtures: ["push.alert.needs-route"],
    });
  });

  it("builds alerts that match the alert fixtures", () => {
    const base = memo({});
    const summary = (base as { summary: never }).summary;
    conforms({
      schema: "push.alert",
      value: buildAlert({ topic: "t", memo: base as never, summary }).payload,
      fixtures: ["push.alert"],
    });
    conforms({
      schema: "push.alert",
      value: buildAlert({ topic: "t", memo: memo({ route: null }) as never, summary }).payload,
      fixtures: ["push.alert.no-route"],
    });
  });
});

const query = (stem: string) =>
  new URLSearchParams(
    Object.entries(fixture(stem).value as Record<string, unknown>).map(
      ([k, v]): [string, string] => [k, String(v)],
    ),
  ).toString();

describe("request fixtures are accepted by the server", () => {
  it("create, complete, retry, query strings", async () => {
    const { app, db } = testApp({ handlers: handlers() });
    // A request fixture that names a thread continues one that already exists.
    for (const f of [...fixturesOf("memos.create.request"), ...fixturesOf("memos.text.request")]) {
      const threadId = (f.value as { threadId?: string }).threadId;
      if (threadId === undefined) continue;
      db.query(
        `INSERT OR IGNORE INTO threads (id, kind, title, created_at, updated_at)
         VALUES (?, 'chat', 'earlier turn', '2026-03-14T09:00:00.000Z', '2026-03-14T09:00:00.000Z')`,
      ).run(threadId);
    }
    for (const f of fixturesOf("memos.create.request")) {
      const res = await call(app, { method: "POST", path: "/v1/memos", json: f.value });
      expect([f.stem, res.status < 300]).toEqual([f.stem, true]);
    }

    for (const f of fixturesOf("memos.text.request")) {
      const res = await call(app, { method: "POST", path: "/v1/memos/text", json: f.value });
      expect([f.stem, res.status]).toEqual([f.stem, 202]);
    }

    const toComplete = crypto.randomUUID();
    await create(app, toComplete);
    for (let n = 0; n < 4; n++) await upload(app, toComplete, n);
    for (const f of fixturesOf("memos.complete.request")) {
      const res = await call(app, {
        method: "POST",
        path: `/v1/memos/${toComplete}/complete`,
        json: f.value,
      });
      expect([f.stem, res.status]).toEqual([f.stem, 202]);
    }

    for (const f of fixturesOf("memos.list.query")) {
      const res = await call(app, { path: `/v1/memos?${query(f.stem)}` });
      expect([f.stem, res.status]).toEqual([f.stem, 200]);
    }
    for (const f of fixturesOf("threads.list.query")) {
      const res = await call(app, { path: `/v1/threads?${query(f.stem)}` });
      expect([f.stem, res.status]).toEqual([f.stem, 200]);
    }
    for (const f of fixturesOf("stats.query")) {
      const res = await call(app, { path: `/v1/stats?${query(f.stem)}` });
      expect([f.stem, res.status]).toEqual([f.stem, 200]);
      await conformingBody({ route: "GET /v1/stats", res });
    }
    for (const f of fixturesOf("memos.result.query")) {
      const res = await call(app, { path: `/v1/memos/${toComplete}/result?${query(f.stem)}` });
      expect([f.stem, res.status]).toEqual([f.stem, 200]);
    }
  });

  it("flags accepts its request fixtures", async () => {
    const { app } = testApp({ handlers: handlers() });
    const id = await record(app);
    for (const f of fixturesOf("memos.flags.request")) {
      const res = await call(app, { method: "PATCH", path: `/v1/memos/${id}`, json: f.value });
      expect([f.stem, res.status]).toEqual([f.stem, 200]);
    }
  });

  it("retry from every fixture step on a memo that failed at notify", async () => {
    const failsAtNotify = handlers({
      notify: async () => {
        throw new Error("apns unreachable");
      },
    });
    for (const f of fixturesOf("memos.retry.request")) {
      const { app } = testApp({ handlers: failsAtNotify });
      const id = await record(app);
      const res = await call(app, { method: "POST", path: `/v1/memos/${id}/retry`, json: f.value });
      expect([f.stem, res.status]).toEqual([f.stem, 202]);
    }
  });

  it("route accepts its request fixtures", async () => {
    for (const f of fixturesOf("memos.route.request")) {
      const { app } = testApp({
        destinations: ["hermes", "herdr"],
        handlers: handlers({ route: async () => ({ outcome: "needs_route" }) }),
      });
      const id = await record(app);
      const res = await call(app, {
        method: "POST",
        path: `/v1/memos/${id}/route`,
        json: f.value,
      });
      expect([f.stem, res.status]).toEqual([f.stem, 202]);
    }
  });

  it("activity-token accepts its fixture, and the server rejects non-hex tokens", async () => {
    const { app } = testApp({ handlers: handlers() });
    const id = await record(app);
    for (const f of fixturesOf("memos.activity-token.request")) {
      const res = await call(app, {
        method: "PUT",
        path: `/v1/memos/${id}/activity-token`,
        json: f.value,
      });
      expect([f.stem, res.status]).toEqual([f.stem, 204]);
    }
    const bad = await call(app, {
      method: "PUT",
      path: `/v1/memos/${id}/activity-token`,
      json: { token: "not hex" },
    });
    expect(bad.status).toBe(400);
  });
});
