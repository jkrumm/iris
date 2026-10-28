import { describe, expect, it } from "bun:test";
import { createApp } from "../app.js";
import type { MemoPatch } from "../memo/memo.js";
import { seedMemo } from "../memo/test-support.js";
import { fakeCombiner, fakeSpeaker } from "../ports/fakes.js";
import { parseDeviceTokens } from "./auth.js";
import { parseRange } from "./media.js";
import { call, TOKENS, testApp } from "./test-support.js";

type Harness = ReturnType<typeof testApp>;

/** A received memo with two stored segments. */
function received(h: Harness) {
  const memo = seedMemo(h.store, "received");
  h.store.recordSegment({ id: memo.id, index: 1, bytes: 1, sha256: "b" });
  h.store.recordSegment({ id: memo.id, index: 0, bytes: 1, sha256: "a" });
  return memo.id;
}

const audio = (h: Harness, id: string, range?: string) =>
  call(h.app, {
    path: `/v1/memos/${id}/audio`,
    headers: { authorization: "Bearer tok-phone", ...(range && { range }) },
  });

const BYTES = Array.from({ length: 100 }, (_, i) => i);
const body = async (res: Response) => [...new Uint8Array(await res.arrayBuffer())];

describe("parseRange", () => {
  it("parses closed, open-ended and suffix ranges, clamping to the size", () => {
    expect(parseRange("bytes=0-9", 100)).toEqual({ start: 0, end: 9 });
    expect(parseRange("bytes=90-", 100)).toEqual({ start: 90, end: 99 });
    expect(parseRange("bytes=90-500", 100)).toEqual({ start: 90, end: 99 });
    expect(parseRange("bytes=-10", 100)).toEqual({ start: 90, end: 99 });
    expect(parseRange("bytes=-500", 100)).toEqual({ start: 0, end: 99 });
  });

  it("flags ranges past the end as unsatisfiable", () => {
    expect(parseRange("bytes=100-", 100)).toBe("unsatisfiable");
    expect(parseRange("bytes=150-160", 100)).toBe("unsatisfiable");
    expect(parseRange("bytes=-0", 100)).toBe("unsatisfiable");
    expect(parseRange("bytes=0-", 0)).toBe("unsatisfiable");
  });

  it("ignores absent, malformed, inverted and multi ranges", () => {
    expect(parseRange(null, 100)).toBeNull();
    expect(parseRange("items=0-9", 100)).toBeNull();
    expect(parseRange("bytes=-", 100)).toBeNull();
    expect(parseRange("bytes=9-0", 100)).toBeNull();
    expect(parseRange("bytes=0-4,10-14", 100)).toBeNull();
    expect(parseRange("bytes=a-b", 100)).toBeNull();
  });
});

describe("GET /v1/memos/:id/audio", () => {
  it("serves the whole recording with the range headers a player needs", async () => {
    const h = testApp();
    const id = received(h);
    const res = await audio(h, id);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("audio/mp4");
    expect(res.headers.get("accept-ranges")).toBe("bytes");
    expect(res.headers.get("content-length")).toBe("100");
    expect(await body(res)).toEqual(BYTES);
  });

  it("combines the segments in index order, once, then serves the cached recording", async () => {
    const h = testApp();
    const id = received(h);
    await audio(h, id);
    await audio(h, id, "bytes=0-9");
    expect(h.combiner.calls).toEqual([[`/fake/${id}/0.m4a`, `/fake/${id}/1.m4a`]]);
    expect(h.audio.combined.get(id)).toEqual(new Uint8Array(BYTES));
  });

  it("shares one combine between concurrent first requests", async () => {
    const h = testApp();
    const id = received(h);
    const results = await Promise.all([audio(h, id), audio(h, id), audio(h, id)]);
    expect(results.map((r) => r.status)).toEqual([200, 200, 200]);
    expect(h.combiner.calls).toHaveLength(1);
  });

  it("answers a closed range with 206 and Content-Range", async () => {
    const h = testApp();
    const id = received(h);
    const res = await audio(h, id, "bytes=10-19");
    expect(res.status).toBe(206);
    expect(res.headers.get("content-range")).toBe("bytes 10-19/100");
    expect(res.headers.get("content-length")).toBe("10");
    expect(res.headers.get("accept-ranges")).toBe("bytes");
    expect(res.headers.get("content-type")).toBe("audio/mp4");
    expect(await body(res)).toEqual(BYTES.slice(10, 20));
  });

  it("answers open-ended and suffix ranges, clamping the end", async () => {
    const h = testApp();
    const id = received(h);
    const open = await audio(h, id, "bytes=95-");
    expect(open.status).toBe(206);
    expect(open.headers.get("content-range")).toBe("bytes 95-99/100");
    expect(await body(open)).toEqual(BYTES.slice(95));

    const suffix = await audio(h, id, "bytes=-4");
    expect(suffix.headers.get("content-range")).toBe("bytes 96-99/100");
    expect(await body(suffix)).toEqual(BYTES.slice(96));

    const clamped = await audio(h, id, "bytes=98-1000");
    expect(clamped.headers.get("content-range")).toBe("bytes 98-99/100");
  });

  it("416s a range past the end, naming the size", async () => {
    const h = testApp();
    const id = received(h);
    const res = await audio(h, id, "bytes=100-");
    expect(res.status).toBe(416);
    expect(res.headers.get("content-range")).toBe("bytes */100");
    expect(res.headers.get("accept-ranges")).toBe("bytes");
  });

  it("serves the whole body for a range it cannot parse", async () => {
    const h = testApp();
    const id = received(h);
    const res = await audio(h, id, "bytes=0-4,10-14");
    expect(res.status).toBe(200);
    expect(await body(res)).toEqual(BYTES);
  });

  it("409s a soft-deleted memo until it is restored", async () => {
    const h = testApp();
    const id = received(h);
    h.store.markDeleted({ id, at: "2026-01-01T00:00:00.000Z" });
    const res = await audio(h, id);
    expect(res.status).toBe(409);
    expect(await res.json()).toMatchObject({ error: "bad_state" });
    expect(h.combiner.calls).toHaveLength(0);

    h.store.restore(id);
    expect((await audio(h, id)).status).toBe(200);
  });

  it("404s an unknown memo and 409s one that is still receiving", async () => {
    const h = testApp();
    const missing = await audio(h, crypto.randomUUID());
    expect(missing.status).toBe(404);
    expect(await missing.json()).toMatchObject({ error: "not_found" });

    const { id } = seedMemo(h.store, "receiving");
    const early = await audio(h, id);
    expect(early.status).toBe(409);
    expect(await early.json()).toMatchObject({ error: "bad_state" });
    expect(h.combiner.calls).toHaveLength(0);
  });

  it("does not cache a failed combine and retries on the next request", async () => {
    let fail = true;
    const combiner = fakeCombiner();
    const flaky = {
      calls: combiner.calls,
      async combine(paths: string[]) {
        if (fail) {
          fail = false;
          combiner.calls.push(paths);
          throw new Error("ffmpeg exploded");
        }
        return combiner.combine(paths);
      },
    };
    const h = testApp({ combiner: flaky as ReturnType<typeof fakeCombiner> });
    const id = received(h);
    expect((await audio(h, id)).status).toBe(500);
    expect((await audio(h, id)).status).toBe(200);
  });

  it("401s without a token", async () => {
    const h = testApp();
    const id = received(h);
    expect((await call(h.app, { path: `/v1/memos/${id}/audio`, headers: {} })).status).toBe(401);
  });

  it("503s when media is not configured", async () => {
    const { memos } = testApp();
    const bare = createApp({ deviceTokens: parseDeviceTokens(TOKENS), memos });
    const res = await call(bare, { path: `/v1/memos/${crypto.randomUUID()}/audio` });
    expect(res.status).toBe(503);
  });
});

const speech = (h: Harness, id: string) => call(h.app, { path: `/v1/memos/${id}/speech` });

/** Sets the step-written fields the way the pipeline would. */
function withResult(h: Harness, patch: MemoPatch) {
  const memo = seedMemo(h.store, "acted");
  h.store.transition({ id: memo.id, from: "acted", to: "summarized" });
  h.store.completeStep({
    id: memo.id,
    step: "summarize",
    from: "summarized",
    to: "summarized",
    patch,
  });
  return memo.id;
}

describe("GET /v1/memos/:id/speech", () => {
  it("speaks summary.spoken plus 'details on screen' for a long reply, as audio/mpeg", async () => {
    const h = testApp();
    const id = withResult(h, {
      summary: { headline: "H", detail: "D", spoken: "Done and dusted." },
      replyText: "This is a long sentence about the migration. ".repeat(30),
    });
    const res = await speech(h, id);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("audio/mpeg");
    expect(new TextDecoder().decode(await res.arrayBuffer())).toBe(
      "mp3:Done and dusted. Details on screen.",
    );
    expect(h.speaker?.calls).toEqual([{ memoId: id, text: "Done and dusted. Details on screen." }]);
  });

  it("speaks a short reply instead of its summary, with the markdown stripped", async () => {
    const h = testApp();
    const id = withResult(h, {
      summary: { headline: "H", detail: "D", spoken: "Done." },
      replyText: "## Result\n\nIt is **fine**, see [docs](https://example.com).",
    });
    await speech(h, id);
    expect(h.speaker?.calls[0]?.text).toBe("Result.\n\nIt is fine, see docs.");
  });

  it("speaks summary.spoken when there is no reply", async () => {
    const h = testApp();
    const id = withResult(h, { summary: { headline: "H", detail: "D", spoken: "Saved." } });
    await speech(h, id);
    expect(h.speaker?.calls[0]?.text).toBe("Saved.");
  });

  it("falls back to replyText when there is no summary", async () => {
    const h = testApp();
    const id = withResult(h, { replyText: "  The reply.  " });
    const res = await speech(h, id);
    expect(new TextDecoder().decode(await res.arrayBuffer())).toBe("mp3:The reply.");
  });

  it("falls back to replyText when the spoken line is blank", async () => {
    const h = testApp();
    const id = withResult(h, {
      summary: { headline: "H", detail: "D", spoken: " " },
      replyText: "The reply.",
    });
    expect((await speech(h, id)).status).toBe(200);
    expect(h.speaker?.calls[0]?.text).toBe("The reply.");
  });

  it("synthesizes once and serves the second request from the cache", async () => {
    const h = testApp();
    const id = withResult(h, { replyText: "The reply." });
    const first = await speech(h, id);
    const second = await speech(h, id);
    expect(await first.text()).toBe(await second.text());
    expect(h.speaker?.calls).toHaveLength(1);
  });

  it("synthesizes again when the text changed after a retry", async () => {
    const h = testApp();
    const id = withResult(h, { replyText: "First." });
    await speech(h, id);
    h.db.query("UPDATE memos SET reply_text = 'Second.' WHERE id = ?").run(id);
    const res = await speech(h, id);
    expect(await res.text()).toBe("mp3:Second.");
    expect(h.speaker?.calls).toHaveLength(2);
  });

  it("409s a soft-deleted memo until it is restored", async () => {
    const h = testApp();
    const { id } = seedMemo(h.store, "notified");
    h.db.query("UPDATE memos SET reply_text = 'First.' WHERE id = ?").run(id);
    h.store.markDeleted({ id, at: "2026-01-01T00:00:00.000Z" });
    const res = await speech(h, id);
    expect(res.status).toBe(409);
    expect(await res.json()).toMatchObject({ error: "bad_state" });
    expect(h.speaker?.calls).toHaveLength(0);

    h.store.restore(id);
    expect((await speech(h, id)).status).toBe(200);
  });

  it("404s an unknown memo and 409s one with nothing to say yet", async () => {
    const h = testApp();
    expect((await speech(h, crypto.randomUUID())).status).toBe(404);

    const { id } = seedMemo(h.store, "received");
    const res = await speech(h, id);
    expect(res.status).toBe(409);
    expect(await res.json()).toMatchObject({ error: "bad_state" });
    expect(h.speaker?.calls).toHaveLength(0);
  });

  it("503s when no speaker is configured", async () => {
    const h = testApp({ speaker: false });
    const id = withResult(h, { replyText: "The reply." });
    const res = await speech(h, id);
    expect(res.status).toBe(503);
    expect(await res.json()).toMatchObject({ error: "unavailable" });
  });

  it("maps a failing synthesis to the speaker's error", async () => {
    const { MemoError } = await import("../memo/errors.js");
    const h = testApp({
      speaker: fakeSpeaker({
        failWith: new MemoError("unavailable", "speech synthesis failed: 502"),
      }),
    });
    const id = withResult(h, { replyText: "The reply." });
    const res = await speech(h, id);
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({
      error: "unavailable",
      message: "speech synthesis failed: 502",
    });
  });
});
