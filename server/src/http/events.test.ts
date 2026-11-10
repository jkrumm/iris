import { describe, expect, it } from "bun:test";
import { markFailed, seedMemo } from "../memo/test-support.js";
import { call, fakeHandlers, testApp } from "./test-support.js";

/** Reads decoded chunks from an SSE body until `done` says enough, or the deadline passes. */
async function readUntil(
  reader: { read(): Promise<{ done: boolean; value?: Uint8Array | undefined }> },
  done: (text: string) => boolean,
) {
  const decoder = new TextDecoder();
  let text = "";
  const deadline = Date.now() + 2000;
  while (!done(text) && Date.now() < deadline) {
    const part = await Promise.race([reader.read(), Bun.sleep(200).then(() => null)]);
    if (part?.value) text += decoder.decode(part.value, { stream: true });
    if (part?.done) break;
  }
  return text;
}

describe("GET /v1/events", () => {
  it("401s without a token", async () => {
    const { app } = testApp();
    const res = await call(app, { path: "/v1/events", headers: {} });
    expect(res.status).toBe(401);
  });

  it("streams ready, memo.updated events and keepalives, then releases on cancel", async () => {
    const { app, listenerCount } = testApp({ sseKeepaliveMs: 20 });
    const res = await call(app, { path: "/v1/events" });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("text/event-stream");
    expect(listenerCount()).toBe(1);
    const reader = (res.body as ReadableStream<Uint8Array>).getReader();

    const id = crypto.randomUUID();
    await call(app, {
      method: "POST",
      path: "/v1/memos",
      json: { id, mode: "auto", startedAt: "2026-01-01T00:00:00.000Z" },
    });

    const text = await readUntil(
      reader,
      (t) => t.includes("memo.updated") && t.includes(": keepalive"),
    );
    expect(text.startsWith("event: ready")).toBe(true);
    const dataLine = text.split("\n").find((l) => l.startsWith('data: {"id"'));
    expect(JSON.parse((dataLine as string).slice(6))).toEqual({
      id,
      state: "receiving",
      step: null,
      failedStep: null,
      error: null,
      at: "2026-01-01T00:00:00.000Z",
    });
    expect(text).toContain(": keepalive");

    await reader.cancel();
    expect(listenerCount()).toBe(0);
  });

  it("adds memo.done after memo.updated only for result-ready states", async () => {
    const { app, events } = testApp({ sseKeepaliveMs: 1000 });
    const res = await call(app, { path: "/v1/events" });
    const reader = (res.body as ReadableStream<Uint8Array>).getReader();
    const base = { id: crypto.randomUUID(), step: null, failedStep: null, error: null, at: "t" };
    events.publish({ ...base, state: "received" });
    events.publish({ ...base, state: "notified" });

    const text = await readUntil(reader, (t) => t.includes("memo.done"));
    const names = text
      .split("\n")
      .filter((l) => l.startsWith("event: "))
      .map((l) => l.slice(7));
    expect(names).toEqual(["ready", "memo.updated", "memo.updated", "memo.done"]);
    await reader.cancel();
  });

  it("sends memo.updated and no memo.done for a flag change on a finished memo", async () => {
    const { app, events } = testApp({ sseKeepaliveMs: 1000 });
    const res = await call(app, { path: "/v1/events" });
    const reader = (res.body as ReadableStream<Uint8Array>).getReader();
    const base = { id: crypto.randomUUID(), step: null, failedStep: null, error: null, at: "t" };
    events.publish({ ...base, state: "notified", flagChange: true });
    events.publish({ ...base, state: "received" });

    const text = await readUntil(reader, (t) => t.split("memo.updated").length > 2);
    const names = text
      .split("\n")
      .filter((l) => l.startsWith("event: "))
      .map((l) => l.slice(7));
    expect(names).toEqual(["ready", "memo.updated", "memo.updated"]);
    expect(text).not.toContain("flagChange");
    await reader.cancel();
  });

  it("releases when the request aborts", async () => {
    const { app, listenerCount } = testApp({ sseKeepaliveMs: 20 });
    const controller = new AbortController();
    const res = await call(app, { path: "/v1/events", signal: controller.signal });
    expect(listenerCount()).toBe(1);
    controller.abort();
    await Bun.sleep(10);
    expect(listenerCount()).toBe(0);
    await res.body?.cancel().catch(() => undefined);
  });

  it("streams memo.updated for each step of a retried legacy failed(route) memo, then memo.done at notified", async () => {
    const { app, store, runner } = testApp({ sseKeepaliveMs: 1000, handlers: fakeHandlers });
    const id = seedMemo(store, "transcribed").id;
    markFailed(store, { id, step: "route", error: "decide refused" });
    const res = await call(app, { path: "/v1/events" });
    const reader = (res.body as ReadableStream<Uint8Array>).getReader();

    const retry = await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/retry`,
      json: { from: "act" },
    });
    expect(retry.status).toBe(202);
    await runner.idle();

    const text = await readUntil(reader, (t) => t.includes("memo.done"));
    const frames = text
      .split("\n\n")
      .map((block) => block.split("\n"))
      .filter((lines) => lines[0]?.startsWith("event: memo."))
      .map(([name, data]) => [
        (name as string).slice(7),
        (JSON.parse((data as string).slice(6)) as { state: string }).state,
      ]);
    expect(frames.at(-1)).toEqual(["memo.done", "notified"]);
    expect(frames.map(([, state]) => state)).toEqual(
      expect.arrayContaining(["transcribed", "acted", "notified"]),
    );
    expect(frames.map(([, state]) => state)).not.toContain("routed");
    await reader.cancel();
  });

  it("streams memo.delta and memo.activity from the progress bus and releases both subscriptions", async () => {
    const { app, progress, listenerCount } = testApp({ sseKeepaliveMs: 1000 });
    const res = await call(app, { path: "/v1/events" });
    const reader = (res.body as ReadableStream<Uint8Array>).getReader();
    const turn = progress.begin("memo-1");
    turn.onProgress({ type: "tool", tool: "terminal" });
    turn.onProgress({ type: "text", delta: "\n\nHello" });

    const text = await readUntil(reader, (t) => t.includes("memo.delta"));
    expect(text).toContain(
      'event: memo.activity\ndata: {"id":"memo-1","attempt":1,"tool":"terminal"}\n\n',
    );
    expect(text).toContain(
      'event: memo.delta\ndata: {"id":"memo-1","attempt":1,"seq":1,"text":"Hello"}\n\n',
    );

    await reader.cancel();
    expect(listenerCount()).toBe(0);
    // Published after the cancel: the unsubscribed stream must not be written to.
    turn.onProgress({ type: "tool", tool: "late" });
    turn.end();
  });
});
