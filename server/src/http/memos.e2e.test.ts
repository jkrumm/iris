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
