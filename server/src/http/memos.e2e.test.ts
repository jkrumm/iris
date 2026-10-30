import { afterEach, describe, expect, it } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createApp } from "../app.js";
import { createSqliteMemoStore, openDatabase } from "../adapters/sqlite.js";
import { createMemoEvents } from "../memo/events.js";
import { createRunner } from "../memo/runner.js";
import { createMemoService } from "../memo/service.js";
import { fakeAudio, seedMemo } from "../memo/test-support.js";
import type { StepHandler } from "../memo/runner.js";
import { manualClock } from "../ports/clock.js";
import { parseDeviceTokens } from "./auth.js";
import { call, fakeHandlers, PHONE, TOKENS, testApp } from "./test-support.js";

const bytes = () => new Uint8Array(8).fill(3);
interface Wire {
  items: Array<{ id: string }>;
  nextCursor: string | null;
  segmentCount: number;
  steps: Array<{ step: string; status: string }>;
  [key: string]: unknown;
}
const json = async (res: Response) => (await res.json()) as Wire;

describe("memo lifecycle over HTTP", () => {
  it("runs create → segments → complete → result → detail → list", async () => {
    const { app } = testApp({ handlers: fakeHandlers });
    const id = crypto.randomUUID();
    const put = (n: number) =>
      call(app, {
        method: "PUT",
        path: `/v1/memos/${id}/segments/${n}`,
        headers: { ...PHONE, "content-type": "audio/mp4" },
        body: bytes(),
      });

    const created = await call(app, {
      method: "POST",
      path: "/v1/memos",
      json: { id, mode: "hermes", startedAt: "2026-01-01T00:00:00.000Z" },
    });
    expect(created.status).toBe(201);

    // out of order, one retried
    for (const n of [2, 0, 0]) expect((await put(n)).status).toBe(200);

    const complete = () =>
      call(app, { method: "POST", path: `/v1/memos/${id}/complete`, json: { segmentCount: 4 } });
    const missing = await complete();
    expect(missing.status).toBe(422);
    expect(await json(missing)).toMatchObject({ error: "missing_segments", missing: [1, 3] });

    for (const n of [1, 3]) expect((await put(n)).status).toBe(200);
    expect((await complete()).status).toBe(202);

    const result = await call(app, { path: `/v1/memos/${id}/result?wait=5` });
    expect(result.status).toBe(200);
    expect(await json(result)).toMatchObject({ id, state: "notified", segmentCount: 4 });

    const detail = await json(await call(app, { path: `/v1/memos/${id}` }));
    expect(detail.segmentCount).toBe(4);
    expect(detail.steps.map((s) => [s.step, s.status])).toEqual([
      ["transcribe", "done"],
      ["route", "done"],
      ["act", "done"],
      ["summarize", "done"],
      ["notify", "done"],
    ]);

    // two more memos, then page newest-first with a cursor
    const others: [string, string] = [crypto.randomUUID(), crypto.randomUUID()];
    for (const other of others) {
      await call(app, {
        method: "POST",
        path: "/v1/memos",
        json: { id: other, mode: "auto", startedAt: "2026-01-01T00:00:00.000Z" },
      });
    }
    const page1 = await json(await call(app, { path: "/v1/memos?limit=2" }));
    expect(page1.items.map((m) => m.id)).toEqual([others[1], others[0]]);
    expect(page1.nextCursor).toEqual(expect.any(String));
    const page2 = await json(
      await call(app, { path: `/v1/memos?limit=2&cursor=${page1.nextCursor}` }),
    );
    expect(page2.items.map((m) => m.id)).toEqual([id]);
    expect(page2.nextCursor).toBeNull();
  });
});

describe("mode transcribe over HTTP", () => {
  const START = "2026-01-01T00:00:00.000Z";

  it("ends notified after transcribe and notify alone, with the transcript and no route", async () => {
    const ran: string[] = [];
    const record =
      (step: string, patch?: { transcript: string }): StepHandler =>
      async () => {
        ran.push(step);
        return patch ? { patch } : {};
      };
    const { app } = testApp({
      handlers: {
        transcribe: record("transcribe", { transcript: "buy milk and call the dentist" }),
        route: record("route"),
        act: record("act"),
        summarize: record("summarize"),
        notify: record("notify"),
      },
    });
    const id = crypto.randomUUID();
    expect(
      (
        await call(app, {
          method: "POST",
          path: "/v1/memos",
          json: { id, mode: "transcribe", startedAt: START },
        })
      ).status,
    ).toBe(201);
    await call(app, {
      method: "PUT",
      path: `/v1/memos/${id}/segments/0`,
      headers: { ...PHONE, "content-type": "audio/mp4" },
      body: bytes(),
    });
    await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/complete`,
      json: { segmentCount: 1 },
    });

    const result = await call(app, { path: `/v1/memos/${id}/result?wait=5` });
    expect(result.status).toBe(200);
    expect(await json(result)).toMatchObject({
      id,
      mode: "transcribe",
      state: "notified",
      transcript: "buy milk and call the dentist",
      route: null,
      replyText: null,
      summary: null,
    });
    expect(ran).toEqual(["transcribe", "notify"]);
    const detail = await json(await call(app, { path: `/v1/memos/${id}` }));
    expect(detail.steps.map((s) => [s.step, s.status])).toEqual([
      ["transcribe", "done"],
      ["notify", "done"],
    ]);
  });

  it("ends a typed memo at once: the text is the transcript, only notify runs", async () => {
    const ran: string[] = [];
    const { app } = testApp({
      handlers: {
        ...fakeHandlers,
        route: async () => {
          ran.push("route");
          return {};
        },
        notify: async () => {
          ran.push("notify");
          return {};
        },
      },
    });
    const id = crypto.randomUUID();
    const created = await call(app, {
      method: "POST",
      path: "/v1/memos/text",
      json: { id, mode: "transcribe", startedAt: START, text: "  just keep this  " },
    });
    expect(created.status).toBe(202);
    const result = await call(app, { path: `/v1/memos/${id}/result?wait=5` });
    expect(await json(result)).toMatchObject({
      state: "notified",
      transcript: "just keep this",
      typed: true,
      route: null,
    });
    expect(ran).toEqual(["notify"]);
  });

  it("refuses to continue a thread and a retry from a step it does not have", async () => {
    const { app } = testApp({ handlers: fakeHandlers });
    const threaded = await call(app, {
      method: "POST",
      path: "/v1/memos/text",
      json: {
        id: crypto.randomUUID(),
        mode: "transcribe",
        startedAt: START,
        text: "x",
        threadId: "t",
      },
    });
    expect(threaded.status).toBe(400);
    expect(await json(threaded)).toMatchObject({ error: "bad_request" });
  });

  it("retries a failed notify back to transcribed, not to a summarized state it never had", async () => {
    let fail = true;
    const { app } = testApp({
      handlers: {
        ...fakeHandlers,
        notify: async () => {
          if (fail) throw new Error("apns down");
          return {};
        },
      },
    });
    const id = crypto.randomUUID();
    await call(app, {
      method: "POST",
      path: "/v1/memos/text",
      json: { id, mode: "transcribe", startedAt: START, text: "keep" },
    });
    expect(await json(await call(app, { path: `/v1/memos/${id}/result?wait=5` }))).toMatchObject({
      state: "failed",
      failedStep: "notify",
    });
    fail = false;
    const retried = await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/retry`,
      json: { from: "notify" },
    });
    expect(retried.status).toBe(202);
    expect(await json(await call(app, { path: `/v1/memos/${id}/result?wait=5` }))).toMatchObject({
      state: "notified",
    });
    const bad = await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/retry`,
      json: { from: "act" },
    });
    expect(bad.status).toBe(400);
  });
});

describe("auth on every /v1 route", () => {
  it("401s without a token", async () => {
    const { app } = testApp();
    const id = crypto.randomUUID();
    const routes: Array<[string, string]> = [
      ["POST", "/v1/memos"],
      ["PUT", `/v1/memos/${id}/segments/0`],
      ["POST", `/v1/memos/${id}/complete`],
      ["POST", `/v1/memos/${id}/retry`],
      ["GET", "/v1/memos"],
      ["GET", `/v1/memos/${id}`],
      ["GET", `/v1/memos/${id}/result`],
      ["GET", "/v1/events"],
    ];
    for (const [method, path] of routes) {
      const res = await call(app, {
        method,
        path,
        headers: {},
        ...(method === "POST" && { json: {} }),
        ...(method === "PUT" && { body: bytes() }),
      });
      expect([method, path, res.status]).toEqual([method, path, 401]);
    }
  });
});

describe("restart recovery", () => {
  let dir = "";
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it("resumes a mid-pipeline memo from a file-backed database", async () => {
    dir = mkdtempSync(join(tmpdir(), "iris-restart-"));
    const file = join(dir, "iris.db");
    const clock = manualClock();

    const before = openDatabase(file);
    const id = seedMemo(createSqliteMemoStore({ db: before, clock }), "transcribed").id;
    before.close();

    const db = openDatabase(file);
    const store = createSqliteMemoStore({ db, clock });
    const events = createMemoEvents();
    const runner = createRunner({ store, handlers: fakeHandlers, events, clock });
    const memos = createMemoService({
      store,
      runner,
      events,
      audio: fakeAudio(),
      clock,
      maxSegmentBytes: 1024,
    });
    const app = createApp({ deviceTokens: parseDeviceTokens(TOKENS), memos });

    await runner.driveAll();
    const res = await call(app, { path: `/v1/memos/${id}` });
    expect(await json(res)).toMatchObject({ id, state: "notified" });
    db.close();
  });
});
