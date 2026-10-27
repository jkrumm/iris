import { describe, expect, it } from "bun:test";
import { parkMemo } from "../memo/test-support.js";
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

  it("streams memo.updated (routed) when a parked memo is answered, then memo.done at notified", async () => {
    const { app, store, runner } = testApp({ sseKeepaliveMs: 1000, handlers: fakeHandlers });
    const id = parkMemo(store, { reason: "decide refused" });
    const res = await call(app, { path: "/v1/events" });
    const reader = (res.body as ReadableStream<Uint8Array>).getReader();

    await call(app, {
      method: "POST",
      path: `/v1/memos/${id}/route`,
      json: { destination: "hermes" },
    });
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
    expect(frames).toEqual([
      ["memo.updated", "routed"],
      ["memo.updated", "acted"],
      ["memo.updated", "summarized"],
      ["memo.updated", "notified"],
      ["memo.done", "notified"],
    ]);
    await reader.cancel();
  });
});
