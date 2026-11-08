import { describe, expect, it } from "bun:test";
import { MemoError, type MemoErrorCode } from "./errors.js";
import { createMemoEvents, type MemoEvent, type MemoEvents } from "./events.js";
import { MEMO_MODES, type HandlerStep } from "./memo.js";
import { createRunner, type StepHandler } from "./runner.js";
import { createMemoService } from "./service.js";
import {
  captureLogs,
  deferred,
  fakeAudio,
  legacyParkedMemo,
  seedMemo,
  testStore,
} from "./test-support.js";

const bytes = (n = 4) => new Uint8Array(n).fill(7);

function setup(
  handlers: Partial<Record<HandlerStep, StepHandler>> = {},
  maxSegmentBytes = 16,
  hermes = true,
) {
  const { store, clock } = testStore();
  const base = createMemoEvents();
  let listeners = 0;
  const events: MemoEvents = {
    publish: (e) => base.publish(e),
    subscribe(listener) {
      listeners++;
      const off = base.subscribe(listener);
      return () => {
        listeners--;
        off();
      };
    },
  };
  const audio = fakeAudio();
  const runner = createRunner({ store, handlers, events, clock });
  const service = createMemoService({
    store,
    runner,
    events,
    audio,
    clock,
    maxSegmentBytes,
    hermes,
  });
  return { store, clock, events, audio, runner, service, listenerCount: () => listeners };
}

const input = (id: string = crypto.randomUUID(), device = "iphone") => ({
  id,
  mode: "auto" as const,
  device,
  startedAt: "2026-01-01T00:00:00.000Z",
});

async function codeOf(work: () => unknown): Promise<MemoErrorCode | "none"> {
  try {
    await work();
  } catch (err) {
    if (err instanceof MemoError) return err.code;
    throw err;
  }
  return "none";
}

describe("createMemo", () => {
  it("is idempotent for the same device and conflicts for another", () => {
    const { service } = setup();
    const params = input();
    expect(service.createMemo(params).created).toBe(true);
    expect(service.createMemo(params).created).toBe(false);
    expect(() => service.createMemo({ ...params, device: "macbook" })).toThrow(MemoError);
  });

  it("publishes once, on creation only", () => {
    const { service, events } = setup();
    const seen: MemoEvent[] = [];
    events.subscribe((e) => seen.push(e));
    const params = input();
    service.createMemo(params);
    service.createMemo(params);
    expect(seen).toHaveLength(1);
    expect(seen[0]).toMatchObject({ state: "receiving", step: null });
  });

  it("rejects ids that are not UUIDs, unknown modes and bad timestamps", async () => {
    const { service } = setup();
    expect(await codeOf(() => service.createMemo(input("../x")))).toBe("bad_request");
    expect(await codeOf(() => service.createMemo({ ...input(), mode: "nope" as never }))).toBe(
      "bad_request",
    );
    expect(await codeOf(() => service.createMemo({ ...input(), startedAt: "yesterday" }))).toBe(
      "bad_request",
    );
  });
});

const typed = (id: string = crypto.randomUUID(), text = "  kauf Milch \n") => ({
  ...input(id),
  text,
});

describe("createTextMemo", () => {
  it("creates a transcribed memo with the trimmed text, publishes once and drives from act", async () => {
    const seen: string[] = [];
    const { service, events, runner } = setup({
      act: async () => {
        seen.push("act");
        return {};
      },
    });
    const published: MemoEvent[] = [];
    events.subscribe((e) => published.push(e));
    const params = typed();
    const { memo, created } = service.createTextMemo(params);
    expect(created).toBe(true);
    expect(memo).toMatchObject({ state: "transcribed", transcript: "kauf Milch" });
    expect(published[0]).toMatchObject({ state: "transcribed", step: null });
    await runner.idle();
    expect(seen).toEqual(["act"]);
    expect(service.get(params.id).steps.map((s) => s.step)).toEqual(["act"]);
    expect(service.get(params.id).segmentCount).toBe(0);
  });

  it("is idempotent for the same body, conflicts for another body, mode, time or device", () => {
    const { service } = setup();
    const params = typed();
    expect(service.createTextMemo(params).created).toBe(true);
    expect(service.createTextMemo({ ...params, text: "kauf Milch" }).created).toBe(false);
    for (const other of [
      { text: "etwas anderes" },
      { mode: "hermes" as const },
      { startedAt: "2026-01-02T00:00:00.000Z" },
      { device: "macbook" },
    ]) {
      expect(() => service.createTextMemo({ ...params, ...other })).toThrow(MemoError);
    }
  });

  it("conflicts with a recorded memo of the same id", () => {
    const { service } = setup();
    const params = input();
    service.createMemo(params);
    expect(() => service.createTextMemo({ ...params, text: "hallo" })).toThrow(MemoError);
  });

  it("rejects empty, whitespace-only and oversized text, bad ids, modes and timestamps", async () => {
    const { service } = setup();
    expect(await codeOf(() => service.createTextMemo(typed(undefined, "")))).toBe("bad_request");
    expect(await codeOf(() => service.createTextMemo(typed(undefined, " \n\t ")))).toBe(
      "bad_request",
    );
    expect(await codeOf(() => service.createTextMemo(typed(undefined, "x".repeat(20_001))))).toBe(
      "bad_request",
    );
    expect(
      await codeOf(() => service.createTextMemo(typed(undefined, `  ${"x".repeat(20_000)}  `))),
    ).toBe("none");
    // The limit counts code points: an emoji is two UTF-16 units but one character.
    expect(await codeOf(() => service.createTextMemo(typed(undefined, "😀".repeat(20_001))))).toBe(
      "bad_request",
    );
    expect(await codeOf(() => service.createTextMemo(typed(undefined, "😀".repeat(20_000))))).toBe(
      "none",
    );
    expect(await codeOf(() => service.createTextMemo(typed("../x")))).toBe("bad_request");
    expect(await codeOf(() => service.createTextMemo({ ...typed(), mode: "nope" as never }))).toBe(
      "bad_request",
    );
    expect(await codeOf(() => service.createTextMemo({ ...typed(), startedAt: "gestern" }))).toBe(
      "bad_request",
    );
  });

  it("retries a failed typed memo from act, and refuses transcribe: there is no audio", async () => {
    let fail = true;
    const { service, runner } = setup({
      act: async () => {
        if (fail) throw new Error("boom");
        return {};
      },
    });
    const params = typed();
    service.createTextMemo(params);
    await runner.idle();
    expect(service.get(params.id).memo.state).toBe("failed");
    expect(await codeOf(() => service.retry({ id: params.id, from: "transcribe" }))).toBe(
      "bad_request",
    );
    expect(service.get(params.id).memo).toMatchObject({
      state: "failed",
      transcript: "kauf Milch",
    });
    fail = false;
    expect(service.retry({ id: params.id, from: "act" }).state).toBe("transcribed");
    await runner.idle();
    expect(service.get(params.id).memo.transcript).toBe("kauf Milch");
  });
});

describe("putSegment", () => {
  it("stores audio and records the segment with its sha256", async () => {
    const { service, audio, store } = setup();
    const { memo } = service.createMemo(input());
    await service.putSegment({ id: memo.id, index: 0, bytes: bytes(4) });
    expect(audio.files.get(`${memo.id}/0`)?.byteLength).toBe(4);
    expect(store.listSegmentIndices(memo.id)).toEqual([0]);
    expect(store.getSegment({ id: memo.id, index: 0 })?.sha256).toBe(
      new Bun.CryptoHasher("sha256").update(bytes(4)).digest("hex"),
    );
  });

  it("is a no-op for the same bytes and a conflict for different bytes, keeping the file", async () => {
    const { service, audio } = setup();
    const { memo } = service.createMemo(input());
    await service.putSegment({ id: memo.id, index: 0, bytes: bytes(4) });
    let writes = 0;
    const put = audio.put.bind(audio);
    audio.put = async (params) => {
      writes++;
      return put(params);
    };
    await service.putSegment({ id: memo.id, index: 0, bytes: bytes(4) });
    expect(writes).toBe(0);
    expect(await codeOf(() => service.putSegment({ id: memo.id, index: 0, bytes: bytes(2) }))).toBe(
      "conflict",
    );
    expect(writes).toBe(0);
    expect(audio.files.get(`${memo.id}/0`)?.byteLength).toBe(4);
  });

  it("guards unknown memos, bad indices, empty and oversized bodies", async () => {
    const { service } = setup();
    const { memo } = service.createMemo(input());
    const put = (over: Partial<{ id: string; index: number; bytes: Uint8Array }>) =>
      service.putSegment({ id: memo.id, index: 0, bytes: bytes(), ...over });
    expect(await codeOf(() => put({ id: crypto.randomUUID() }))).toBe("not_found");
    expect(await codeOf(() => put({ index: -1 }))).toBe("bad_request");
    expect(await codeOf(() => put({ index: 1.5 }))).toBe("bad_request");
    expect(await codeOf(() => put({ bytes: new Uint8Array() }))).toBe("bad_request");
    expect(await codeOf(() => put({ bytes: bytes(17) }))).toBe("too_large");
  });

  it("keeps the stored file and sha in agreement when same-index uploads race", async () => {
    const { service, audio, store } = setup();
    const { memo } = service.createMemo(input());
    const first = new Uint8Array(4).fill(1);
    const second = new Uint8Array(4).fill(2);
    const results = await Promise.all([
      codeOf(() => service.putSegment({ id: memo.id, index: 0, bytes: first })),
      codeOf(() => service.putSegment({ id: memo.id, index: 0, bytes: second })),
    ]);
    expect(results).toEqual(["none", "conflict"]);
    expect(audio.files.get(`${memo.id}/0`)).toEqual(first);
    expect(store.getSegment({ id: memo.id, index: 0 })?.bytes).toBe(4);
  });

  it("rejects a segment whose write was still in flight when complete ran", async () => {
    const { service, audio, store } = setup();
    const { memo } = service.createMemo(input());
    await service.putSegment({ id: memo.id, index: 0, bytes: bytes() });
    const gate = deferred();
    const put = audio.put.bind(audio);
    audio.put = async (params) => {
      await gate.promise;
      return put(params);
    };
    const late = codeOf(() => service.putSegment({ id: memo.id, index: 1, bytes: bytes() }));
    service.complete({ id: memo.id, segmentCount: 1 });
    gate.resolve();
    expect(await late).toBe("bad_state");
    expect(store.listSegmentIndices(memo.id)).toEqual([0]);
    expect([...audio.files.keys()]).toEqual([`${memo.id}/0`]);
  });

  it("removes the file of a segment whose write was in flight when its memo was deleted, and keeps the recorded ones", async () => {
    const { service, audio, store } = setup();
    const { memo } = service.createMemo(input());
    await service.putSegment({ id: memo.id, index: 0, bytes: bytes() });
    const gate = deferred();
    const put = audio.put.bind(audio);
    audio.put = async (params) => {
      await gate.promise;
      return put(params);
    };
    const late = codeOf(() => service.putSegment({ id: memo.id, index: 1, bytes: bytes() }));
    service.delete(memo.id);
    gate.resolve();

    expect(await late).toBe("bad_state");
    expect(store.listSegmentIndices(memo.id)).toEqual([0]);
    // Only the unrecorded file went; what the memo has recorded stays for a restore within the undo window.
    expect([...audio.files.keys()]).toEqual([`${memo.id}/0`]);
    expect(service.restore(memo.id).deletedAt).toBeNull();
    expect(store.listSegmentIndices(memo.id)).toEqual([0]);
  });

  it("a failing cleanup of a refused segment is logged and the refusal still reaches the caller", async () => {
    const { service, audio } = setup();
    const { memo } = service.createMemo(input());
    const gate = deferred();
    const put = audio.put.bind(audio);
    audio.put = async (params) => {
      await gate.promise;
      return put(params);
    };
    audio.removeSegment = async () => {
      throw new Error("disk gone");
    };
    const late = codeOf(() => service.putSegment({ id: memo.id, index: 0, bytes: bytes() }));
    service.delete(memo.id);
    gate.resolve();
    const { result, lines } = await captureLogs(() => late);
    expect(result).toBe("bad_state");
    expect(lines.map((l) => l["event"])).toEqual(["segment.cleanup_failed"]);
  });

  it("refuses segments once the memo is past receiving", async () => {
    const { service } = setup();
    const { memo } = service.createMemo(input());
    await service.putSegment({ id: memo.id, index: 0, bytes: bytes() });
    service.complete({ id: memo.id, segmentCount: 1 });
    expect(await codeOf(() => service.putSegment({ id: memo.id, index: 1, bytes: bytes() }))).toBe(
      "bad_state",
    );
  });
});

describe("complete", () => {
  it("lists the missing indices and leaves the memo receiving", async () => {
    const { service } = setup();
    const { memo } = service.createMemo(input());
    await service.putSegment({ id: memo.id, index: 0, bytes: bytes() });
    await service.putSegment({ id: memo.id, index: 3, bytes: bytes() });
    try {
      service.complete({ id: memo.id, segmentCount: 4 });
      throw new Error("expected missing_segments");
    } catch (err) {
      expect(err).toBeInstanceOf(MemoError);
      expect((err as MemoError).code).toBe("missing_segments");
      expect((err as MemoError).payload.missing).toEqual([1, 2]);
    }
    expect(service.get(memo.id).memo.state).toBe("receiving");
    expect(service.get(memo.id).segmentCount).toBe(2);
  });

  it("rejects a stray segment past the count with a conflict and stays receiving", async () => {
    const { service } = setup();
    const { memo } = service.createMemo(input());
    await service.putSegment({ id: memo.id, index: 0, bytes: bytes() });
    await service.putSegment({ id: memo.id, index: 3, bytes: bytes() });
    expect(await codeOf(() => service.complete({ id: memo.id, segmentCount: 1 }))).toBe("conflict");
    expect(service.get(memo.id).memo.state).toBe("receiving");
  });

  it("validates the count and the memo", async () => {
    const { service } = setup();
    const { memo } = service.createMemo(input());
    expect(await codeOf(() => service.complete({ id: memo.id, segmentCount: 0 }))).toBe(
      "bad_request",
    );
    expect(await codeOf(() => service.complete({ id: memo.id, segmentCount: 1.5 }))).toBe(
      "bad_request",
    );
    expect(await codeOf(() => service.complete({ id: crypto.randomUUID(), segmentCount: 1 }))).toBe(
      "not_found",
    );
  });

  it("receives, publishes ingest and drives the pipeline in the background", async () => {
    const ran: HandlerStep[] = [];
    const { service, events, runner } = setup({
      transcribe: async () => {
        ran.push("transcribe");
        return {};
      },
    });
    const seen: MemoEvent[] = [];
    events.subscribe((e) => seen.push(e));
    const { memo } = service.createMemo(input());
    await service.putSegment({ id: memo.id, index: 0, bytes: bytes() });
    const received = service.complete({ id: memo.id, segmentCount: 1 });

    expect(received).toMatchObject({ state: "received", segmentCount: 1 });
    expect(seen.map((e) => e.step)).toEqual([null, "ingest"]);
    await runner.drive(memo.id);
    expect(ran).toEqual(["transcribe"]);
    expect(service.get(memo.id).memo.state).toBe("transcribed");
  });

  it("is idempotent for the same count and conflicts for a different one", async () => {
    const { service } = setup();
    const { memo } = service.createMemo(input());
    await service.putSegment({ id: memo.id, index: 0, bytes: bytes() });
    const first = service.complete({ id: memo.id, segmentCount: 1 });
    const again = service.complete({ id: memo.id, segmentCount: 1 });
    expect(again.id).toBe(first.id);
    expect(await codeOf(() => service.complete({ id: memo.id, segmentCount: 2 }))).toBe("conflict");
  });
});

describe("get, list, retry", () => {
  it("returns the memo with its timeline and 404s unknown ids", async () => {
    const { service, runner } = setup({ transcribe: async () => ({ costUsd: 0.5 }) });
    const { memo } = service.createMemo(input());
    await service.putSegment({ id: memo.id, index: 0, bytes: bytes() });
    service.complete({ id: memo.id, segmentCount: 1 });
    await runner.drive(memo.id);
    const detail = service.get(memo.id);
    expect(detail.segmentCount).toBe(1);
    expect(detail.steps).toHaveLength(1);
    expect(detail.steps[0]).toMatchObject({ step: "transcribe", status: "done", costUsd: 0.5 });
    expect(await codeOf(() => service.get(crypto.randomUUID()))).toBe("not_found");
  });

  it("pages and clamps the limit", () => {
    const { service, store } = setup();
    for (let i = 0; i < 3; i++) seedMemo(store);
    const page = service.list({ limit: 2 });
    expect(page.memos).toHaveLength(2);
    expect(service.list({ limit: 0 }).memos).toHaveLength(1);
    expect(service.list({ limit: 1000 }).memos).toHaveLength(3);
    expect(service.list({ cursor: page.nextCursor }).memos).toHaveLength(1);
  });

  it("retries a failed memo through the runner", async () => {
    let fail = true;
    const { service, runner, store } = setup({
      transcribe: async () => {
        if (fail) throw new Error("boom");
        return {};
      },
    });
    const memo = seedMemo(store, "received");
    await runner.drive(memo.id);
    expect(service.get(memo.id).memo.state).toBe("failed");
    fail = false;
    expect(service.retry({ id: memo.id, from: "transcribe" }).state).toBe("received");
    await runner.drive(memo.id);
    expect(service.get(memo.id).memo.state).toBe("transcribed");
  });
});

describe("waitForResult", () => {
  it("answers immediately for a result-ready memo, without subscribing", async () => {
    const { service, store, listenerCount } = setup();
    const done = seedMemo(store, "notified");
    const result = await service.waitForResult({ id: done.id, waitSeconds: 5 });
    expect(result).toMatchObject({ ready: true });
    expect(result.memo.state).toBe("notified");
    expect(listenerCount()).toBe(0);
  });

  it("resolves as soon as the memo reaches a result state", async () => {
    const { service, runner, store, listenerCount } = setup({
      transcribe: async () => ({}),
      act: async () => ({}),
      summarize: async () => ({}),
      notify: async () => ({}),
    });
    const memo = seedMemo(store, "received");
    const waiting = service.waitForResult({ id: memo.id, waitSeconds: 5 });
    expect(listenerCount()).toBe(1);
    await runner.drive(memo.id);
    const result = await waiting;
    expect(result.ready).toBe(true);
    expect(result.memo.state).toBe("notified");
    expect(listenerCount()).toBe(0);
  });

  it("answers immediately for an old memo parked at needs_route", async () => {
    const { service, store, listenerCount } = setup();
    const id = legacyParkedMemo(store);
    const result = await service.waitForResult({ id, waitSeconds: 5 });
    expect(result).toMatchObject({ ready: true });
    expect(result.memo.state).toBe("needs_route");
    expect(listenerCount()).toBe(0);
  });

  it("ignores events of other memos and times out with the current state", async () => {
    const { service, store, events, listenerCount } = setup();
    const memo = seedMemo(store, "received");
    const waiting = service.waitForResult({ id: memo.id, waitSeconds: 0.02 });
    events.publish({
      id: crypto.randomUUID(),
      state: "notified",
      step: "notify",
      failedStep: null,
      error: null,
      at: "2026-01-01T00:00:00.000Z",
    });
    const result = await waiting;
    expect(result.ready).toBe(false);
    expect(result.memo.state).toBe("received");
    expect(listenerCount()).toBe(0);
  });

  it("aborts without leaking its listener or timer", async () => {
    const { service, store, listenerCount } = setup();
    const memo = seedMemo(store, "received");
    const controller = new AbortController();
    const waiting = service.waitForResult({
      id: memo.id,
      waitSeconds: 60,
      signal: controller.signal,
    });
    expect(listenerCount()).toBe(1);
    controller.abort();
    expect((await waiting).ready).toBe(false);
    expect(listenerCount()).toBe(0);
  });

  it("returns at once for an already-aborted signal and 404s unknown memos", async () => {
    const { service, store, listenerCount } = setup();
    const memo = seedMemo(store, "received");
    const result = await service.waitForResult({
      id: memo.id,
      waitSeconds: 60,
      signal: AbortSignal.abort(),
    });
    expect(result.ready).toBe(false);
    expect(listenerCount()).toBe(0);
    expect(await codeOf(() => service.waitForResult({ id: "nope", waitSeconds: 1 }))).toBe(
      "not_found",
    );
  });
});

describe("subscribe", () => {
  it("relays pipeline events and unsubscribes", async () => {
    const { service } = setup();
    const seen: MemoEvent[] = [];
    const off = service.subscribe((e) => seen.push(e));
    service.createMemo(input());
    off();
    service.createMemo(input());
    expect(seen).toHaveLength(1);
  });
});

/** A thread the way `act` leaves it: a memo that ran in Hermes session `threadId`. */
function seedThread(store: ReturnType<typeof testStore>["store"], threadId: string) {
  const memo = seedMemo(store, "transcribed");
  store.completeStep({
    id: memo.id,
    step: "act",
    from: "transcribed",
    to: "acted",
    patch: {
      destinationRef: threadId,
      replyText: "ok",
      thread: { id: threadId, kind: "hermes", title: "first" },
    },
  });
  return threadId;
}

describe("list", () => {
  it("normalises the kind filter like the stored kind and matches nothing for blank text", () => {
    const { service, store } = setup();
    const shopping = seedMemo(store, "transcribed");
    store.completeStep({
      id: shopping.id,
      step: "act",
      from: "transcribed",
      to: "acted",
      patch: { kind: "shopping", actions: ["search"] },
    });
    seedMemo(store, "transcribed");

    expect(service.list({}).memos).toHaveLength(2);
    for (const kind of ["shopping", "  Shopping ", "SHOPPING"]) {
      expect(service.list({ kind }).memos.map((m) => m.id)).toEqual([shopping.id]);
    }
    expect(service.list({ kind: "shopping" }).memos[0]).toMatchObject({
      kind: "shopping",
      actions: ["search"],
    });
    expect(service.list({ kind: "recipes" }).memos).toEqual([]);
    expect(service.list({ kind: "" }).memos).toEqual([]);
    expect(service.list({ kind: "   " }).memos).toEqual([]);
  });

  it("keeps only the memos of a conversation with the thread filter", () => {
    const { service, store } = setup();
    seedThread(store, "solo");
    seedThread(store, "thread-1");
    seedThread(store, "thread-1");
    seedMemo(store, "transcribed");

    expect(service.list({}).memos).toHaveLength(4);
    const threaded = service.list({ thread: true }).memos;
    expect(threaded).toHaveLength(2);
    expect(threaded.every((m) => m.threadId === "thread-1")).toBe(true);
  });

  it("lists threads with limit and cursor", () => {
    const { service, store } = setup();
    seedThread(store, "thread-1");
    seedThread(store, "thread-2");
    const page = service.listThreads({ limit: 1 });
    expect(page.threads).toHaveLength(1);
    expect(service.listThreads({ cursor: page.nextCursor }).threads).toHaveLength(1);
  });
});

describe("thread continuation", () => {
  it("continues an existing thread when hermes is available", () => {
    const { service, store } = setup({}, 16, true);
    const threadId = seedThread(store, "thread-1");
    const { memo, created } = service.createTextMemo({ ...typed(), threadId });
    expect(created).toBe(true);
    expect(memo.threadId).toBe(threadId);
  });

  it("409s destination_unavailable without hermes, and 404s an unknown thread", async () => {
    const { service, store } = setup({}, 16, false);
    const threadId = seedThread(store, "thread-1");
    expect(await codeOf(() => service.createTextMemo({ ...typed(), threadId }))).toBe(
      "destination_unavailable",
    );
    expect(await codeOf(() => service.createMemo({ ...input(), threadId }))).toBe(
      "destination_unavailable",
    );
    const withHermes = setup();
    expect(
      await codeOf(() => withHermes.service.createTextMemo({ ...typed(), threadId: "nope" })),
    ).toBe("not_found");
  });

  it("400s a thread on a transcribe memo", async () => {
    const { service, store } = setup();
    const threadId = seedThread(store, "thread-1");
    expect(
      await codeOf(() => service.createTextMemo({ ...typed(), mode: "transcribe", threadId })),
    ).toBe("bad_request");
    expect(
      await codeOf(() => service.createMemo({ ...input(), mode: "transcribe", threadId })),
    ).toBe("bad_request");
  });
});

describe("modes", () => {
  it("stores every mode as received on both create routes", () => {
    const { service } = setup();
    for (const mode of MEMO_MODES) {
      expect(service.createMemo({ ...input(), mode }).memo.mode).toBe(mode);
      expect(service.createTextMemo({ ...typed(), mode }).memo.mode).toBe(mode);
    }
  });
});
