import { describe, expect, it } from "bun:test";
import { createMemoEvents } from "../memo/events.js";
import { MEMO_MODES } from "../memo/memo.js";
import { createRunner } from "../memo/runner.js";
import { fakeAudio, seedMemo, testStore } from "../memo/test-support.js";
import {
  FAKE_META,
  fakeAssetStore,
  fakeDestination,
  fakeDiagramRenderer,
  fakeNotifier,
  fakeTranscriber,
} from "../ports/fakes.js";
import { createReplyAssets, type ReplyAssets } from "../memo/reply-assets.js";
import type { MemoStore } from "../memo/store.js";
import { createStepHandlers } from "./steps.js";

type FakeDestination = ReturnType<typeof fakeDestination>;

function setup(
  options: {
    transcriber?: ReturnType<typeof fakeTranscriber>;
    /** `null` leaves the pipeline without Hermes: no `act` handler. */
    destination?: FakeDestination | null;
    notifier?: ReturnType<typeof fakeNotifier>;
    replyAssets?: (store: MemoStore) => ReplyAssets;
  } = {},
) {
  const { store, clock, db } = testStore();
  const audio = fakeAudio();
  const transcriber = options.transcriber ?? fakeTranscriber({ result: { costUsd: 0.02 } });
  const destination =
    options.destination ?? fakeDestination({ result: { usage: { turns: 1 }, costUsd: 0.1 } });
  const notifier = options.notifier ?? fakeNotifier();
  const handlers = createStepHandlers({
    store,
    audio,
    transcriber,
    ...(options.destination !== null && { destination }),
    replyAssets: options.replyAssets?.(store),
    notifier,
  });
  const events = createMemoEvents();
  const runner = createRunner({ store, handlers, events, clock });
  return { store, db, audio, handlers, runner, events, transcriber, destination, notifier };
}

/** A Hermes that answers without the ```iris block: the delivery carries no `meta`. */
function metalessDestination(): FakeDestination {
  const calls: FakeDestination["calls"] = [];
  return {
    calls,
    async deliver(params) {
      calls.push(params);
      return { ref: "session-1", replyText: "plain reply" };
    },
  };
}

function seedWithSegments(store: ReturnType<typeof testStore>["store"], indices: number[]) {
  const memo = seedMemo(store, "received");
  for (const index of indices) {
    store.recordSegment({ id: memo.id, index, bytes: 1, sha256: `sha-${index}` });
  }
  return memo;
}

describe("createStepHandlers", () => {
  it("registers a handler only for a provided port", () => {
    const { store } = testStore();
    const handlers = createStepHandlers({
      store,
      audio: fakeAudio(),
      transcriber: fakeTranscriber(),
      destination: fakeDestination(),
      notifier: fakeNotifier(),
    });
    expect(Object.keys(handlers).toSorted()).toEqual(["act", "notify", "transcribe"]);
  });

  it("registers act only with a destination", () => {
    const { store } = testStore();
    const handlers = createStepHandlers({ store, audio: fakeAudio(), notifier: fakeNotifier() });
    expect(Object.keys(handlers).toSorted()).toEqual(["notify"]);
  });
});

describe("transcribe", () => {
  it("passes the segment paths in ascending order and patches transcript and duration", async () => {
    const { store, handlers, transcriber } = setup();
    const memo = seedWithSegments(store, [2, 0, 1]);
    const result = await handlers.transcribe?.({ memo });

    expect(transcriber.calls[0]).toEqual({
      memoId: memo.id,
      segmentPaths: [0, 1, 2].map((n) => `/fake/${memo.id}/${n}.m4a`),
    });
    expect(result).toEqual({
      patch: { transcript: "hello iris", audioSeconds: 12.5 },
      usage: { audioSeconds: 12.5 },
      costUsd: 0.02,
    });
  });

  it("omits the cost when the port reports none", async () => {
    const { store, handlers } = setup({ transcriber: fakeTranscriber() });
    const result = await handlers.transcribe?.({ memo: seedWithSegments(store, [0]) });
    expect(result).not.toHaveProperty("costUsd");
  });

  it("throws on an empty transcript", async () => {
    const { store, handlers } = setup({
      transcriber: fakeTranscriber({ result: { text: "  \n" } }),
    });
    await expect(handlers.transcribe?.({ memo: seedWithSegments(store, [0]) })).rejects.toThrow(
      "empty transcript",
    );
  });
});

describe("act", () => {
  it("delivers the transcript with the memo's mode and patches the ref, reply, thread, kind, actions and summary", async () => {
    const { store, handlers, destination } = setup();
    const memo = { ...seedMemo(store, "transcribed"), transcript: "do the thing" };
    const result = await handlers.act?.({ memo });
    expect(destination.calls).toEqual([
      { memoId: memo.id, transcript: "do the thing", mode: "auto" },
    ]);
    expect(result).toEqual({
      patch: {
        destinationRef: "session-1",
        replyText: "done",
        thread: { id: "session-1", kind: "hermes", title: "do the thing" },
        kind: "note",
        actions: ["fake_search", "fake_write"],
        summary: FAKE_META.summary,
      },
      usage: { turns: 1 },
      costUsd: 0.1,
    });
  });

  it("passes every mode as the memo has it", async () => {
    const { store, handlers, destination } = setup();
    for (const mode of MEMO_MODES.filter((m) => m !== "transcribe")) {
      const memo = { ...seedMemo(store, "transcribed"), mode, transcript: "t" };
      await handlers.act?.({ memo });
      expect(destination.calls.at(-1)).toEqual({ memoId: memo.id, transcript: "t", mode });
    }
  });

  it("patches null, [] and null when the delivery carries no meta", async () => {
    const destination = metalessDestination();
    const { store, handlers } = setup({ destination });
    const memo = { ...seedMemo(store, "transcribed"), transcript: "plain" };
    const result = await handlers.act?.({ memo });
    expect(result?.patch).toMatchObject({
      replyText: "plain reply",
      kind: null,
      actions: [],
      summary: null,
    });
  });

  it("stores kind, actions and summary with the commit, and a re-run replaces them", async () => {
    const withMeta = setup();
    const { store } = withMeta;
    const memo = { ...seedMemo(store, "transcribed"), transcript: "first" };
    const first = await withMeta.handlers.act?.({ memo });
    store.completeStep({
      id: memo.id,
      step: "act",
      from: "transcribed",
      to: "acted",
      patch: first?.patch ?? {},
    });
    expect(store.getMemo(memo.id)).toMatchObject({
      kind: "note",
      actions: ["fake_search", "fake_write"],
      summary: FAKE_META.summary,
    });

    // The next run of act has no meta: nothing of the first run's survives.
    const rerun = createStepHandlers({
      store,
      audio: fakeAudio(),
      destination: metalessDestination(),
      notifier: fakeNotifier(),
    });
    store.transition({ id: memo.id, from: "acted", to: "transcribed" });
    const second = await rerun.act?.({ memo: { ...memo, state: "transcribed" } });
    store.completeStep({
      id: memo.id,
      step: "act",
      from: "transcribed",
      to: "acted",
      patch: second?.patch ?? {},
    });
    expect(store.getMemo(memo.id)).toMatchObject({
      kind: null,
      actions: [],
      summary: null,
      replyText: "plain reply",
    });
  });

  it("renders the reply's mermaid blocks once it is delivered, and a block that fails never fails the step", async () => {
    const reply = "```mermaid\nA-->B\n```\n```mermaid\nunrenderable\n```";
    const assets = fakeAssetStore();
    const renderer = fakeDiagramRenderer();
    const { store, handlers } = setup({
      destination: fakeDestination({ result: { replyText: reply } }),
      replyAssets: (s) => createReplyAssets({ store: s, assets, renderer }),
    });
    const memo = { ...seedMemo(store, "transcribed"), transcript: "draw it" };
    const result = await handlers.act?.({ memo });

    expect(result?.patch?.replyText).toBe(reply);
    expect(renderer.calls).toEqual(["A-->B", "unrenderable"]);
    // The assets are staged: they reach the wire with the commit of the reply.
    expect(store.getMemo(memo.id)?.replyBlocks).toEqual([]);
    store.completeStep({
      id: memo.id,
      step: "act",
      from: "transcribed",
      to: "acted",
      patch: result?.patch ?? {},
    });
    expect(store.getMemo(memo.id)?.replyBlocks.map((b) => b.index)).toEqual([0]);
    expect(assets.files.size).toBe(4);
  });

  it("persists the thread exactly as the destination reported it", async () => {
    const thread = { id: "other", kind: "hermes" as const, title: "named by the adapter" };
    const { store, handlers } = setup({ destination: fakeDestination({ result: { thread } }) });
    const memo = { ...seedMemo(store, "transcribed"), transcript: "anything" };
    const result = await handlers.act?.({ memo });
    expect(result?.patch?.thread).toEqual(thread);
  });

  it("persists no thread when the destination reports none", async () => {
    const { store, handlers } = setup({ destination: metalessDestination() });
    const memo = { ...seedMemo(store, "transcribed"), transcript: "x" };
    const result = await handlers.act?.({ memo });
    expect(result?.patch).not.toHaveProperty("thread");
  });

  it("omits the cost when the destination reports none", async () => {
    const { store, handlers } = setup({ destination: metalessDestination() });
    const memo = { ...seedMemo(store, "transcribed"), transcript: "x" };
    const result = await handlers.act?.({ memo });
    expect(result).not.toHaveProperty("costUsd");
  });

  it("throws without a transcript", async () => {
    const { store, handlers, destination } = setup();
    await expect(handlers.act?.({ memo: seedMemo(store, "transcribed") })).rejects.toThrow(
      "no transcript",
    );
    expect(destination.calls).toEqual([]);
  });

  it("propagates a delivery failure and writes nothing", async () => {
    const { store, handlers } = setup({
      destination: fakeDestination({ failWith: new Error("hermes down") }),
    });
    const memo = { ...seedMemo(store, "transcribed"), transcript: "t" };
    await expect(handlers.act?.({ memo })).rejects.toThrow("hermes down");
    expect(store.getMemo(memo.id)).toMatchObject({ replyText: null, kind: null, actions: [] });
  });
});

describe("notify", () => {
  it("notifies with the memo and its summary", async () => {
    const { store, handlers, notifier } = setup();
    const summary = { headline: "h", detail: "d", spoken: "s" };
    const memo = { ...seedMemo(store, "acted"), summary };
    expect(await handlers.notify?.({ memo })).toEqual({});
    expect(notifier.calls).toEqual([{ memo, summary }]);
  });

  it("announces a clipped transcript when the memo has no summary", async () => {
    const { store, handlers, notifier } = setup();
    const transcript = `  Bitte   erinnere mich ${"morgen ".repeat(20)}an den Termin `;
    const memo = { ...seedMemo(store, "acted"), transcript };
    expect(await handlers.notify?.({ memo })).toEqual({});
    const [call] = notifier.calls;
    expect(call?.memo).toBe(memo);
    expect(call?.summary.headline).toHaveLength(60);
    expect(call?.summary.headline.startsWith("Bitte erinnere mich morgen morgen")).toBe(true);
    expect(call?.summary.headline.endsWith("…")).toBe(true);
    expect(call?.summary.detail.length).toBeLessThanOrEqual(240);
    expect(call?.summary.spoken).toBe("");
  });

  it("clips the headline at 60 code points, not UTF-16 units", async () => {
    const { store, handlers, notifier } = setup();
    const memo = { ...seedMemo(store, "acted"), transcript: "😀".repeat(70) };
    await handlers.notify?.({ memo });
    const headline = notifier.calls[0]?.summary.headline ?? "";
    expect(Array.from(headline)).toHaveLength(60);
    expect(headline).toBe(`${"😀".repeat(59)}…`);
  });

  it("announces a short transcript whole, with no routing prefix cut", async () => {
    const { store, handlers, notifier } = setup();
    const memo = { ...seedMemo(store, "acted"), transcript: "Hermes, kauf Milch" };
    await handlers.notify?.({ memo });
    expect(notifier.calls[0]?.summary.headline).toBe("Hermes, kauf Milch");
  });

  it("throws when there is neither a summary nor a transcript", async () => {
    const { store, handlers } = setup();
    await expect(handlers.notify?.({ memo: seedMemo(store, "acted") })).rejects.toThrow(
      "no transcript",
    );
  });
});

describe("pipeline end to end", () => {
  it("drives a received memo to notified and stores every result", async () => {
    const { store, runner, notifier } = setup();
    const { id } = seedWithSegments(store, [1, 0]);
    await runner.drive(id);

    expect(store.getMemo(id)).toMatchObject({
      state: "notified",
      audioSeconds: 12.5,
      transcript: "hello iris",
      route: null,
      destinationRef: "session-1",
      replyText: "done",
      kind: "note",
      actions: ["fake_search", "fake_write"],
      summary: { headline: "Headline", detail: "", spoken: "Spoken." },
    });
    expect(store.listStepRecords(id).map((s) => [s.step, s.status, s.usage, s.costUsd])).toEqual([
      ["transcribe", "done", { audioSeconds: 12.5 }, 0.02],
      ["act", "done", { turns: 1 }, 0.1],
      ["notify", "done", null, null],
    ]);
    expect(notifier.calls.map((c) => c.summary.headline)).toEqual(["Headline"]);
  });

  it("announces the transcript when Hermes sent no block", async () => {
    const { store, runner, notifier } = setup({ destination: metalessDestination() });
    const { id } = seedWithSegments(store, [0]);
    await runner.drive(id);
    expect(store.getMemo(id)).toMatchObject({
      state: "notified",
      kind: null,
      actions: [],
      summary: null,
      replyText: "plain reply",
    });
    expect(notifier.calls.map((c) => c.summary.headline)).toEqual(["hello iris"]);
  });

  it("ends a transcribe-mode memo after transcribe, announcing the transcript", async () => {
    const { store, runner, destination, notifier } = setup();
    const id = crypto.randomUUID();
    store.createMemo({
      id,
      mode: "transcribe",
      device: "iphone",
      startedAt: "2026-01-01T00:00:00.000Z",
    });
    store.recordSegment({ id, index: 0, bytes: 1, sha256: "sha-0" });
    store.markReceived({ id, segmentCount: 1 });
    await runner.drive(id);

    expect(store.getMemo(id)).toMatchObject({
      state: "notified",
      transcript: "hello iris",
      route: null,
      replyText: null,
      summary: null,
      kind: null,
      actions: [],
    });
    expect(store.listStepRecords(id).map((s) => [s.step, s.status])).toEqual([
      ["transcribe", "done"],
      ["notify", "done"],
    ]);
    expect(destination.calls).toEqual([]);
    expect(notifier.calls.map((c) => c.summary.headline)).toEqual(["hello iris"]);
  });

  it("waits at transcribed when no destination is configured", async () => {
    const { store, runner, notifier } = setup({ destination: null });
    const { id } = seedWithSegments(store, [0]);
    await runner.drive(id);
    expect(store.getMemo(id)).toMatchObject({ state: "transcribed", failedStep: null });
    expect(notifier.calls).toEqual([]);
  });

  it("fails at act on a delivery failure and recovers with a retry from act, without re-transcribing", async () => {
    const inner = fakeDestination();
    let broken = true;
    const destination: FakeDestination = {
      calls: inner.calls,
      async deliver(params) {
        if (broken) throw new Error("hermes down");
        return inner.deliver(params);
      },
    };
    const { store, runner, transcriber, notifier } = setup({ destination });
    const { id } = seedWithSegments(store, [0]);
    await runner.drive(id);
    expect(store.getMemo(id)).toMatchObject({
      state: "failed",
      failedStep: "act",
      error: "hermes down",
    });

    broken = false;
    runner.retry({ id, from: "act" });
    await runner.idle();

    expect(store.getMemo(id)).toMatchObject({ state: "notified", kind: "note" });
    expect(transcriber.calls).toHaveLength(1);
    expect(notifier.calls).toHaveLength(1);
  });

  it("retries a failed notify without delivering again", async () => {
    let broken = true;
    const inner = fakeNotifier();
    const notifier: ReturnType<typeof fakeNotifier> = {
      ...inner,
      async notify(params) {
        if (broken) throw new Error("apns down");
        return inner.notify(params);
      },
    };
    const { store, runner, destination } = setup({ notifier });
    const { id } = seedWithSegments(store, [0]);
    await runner.drive(id);
    expect(store.getMemo(id)).toMatchObject({ state: "failed", failedStep: "notify" });

    broken = false;
    runner.retry({ id, from: "notify" });
    await runner.idle();

    expect(store.getMemo(id)?.state).toBe("notified");
    expect(destination.calls).toHaveLength(1);
    expect(inner.calls.map((c) => c.summary.headline)).toEqual(["Headline"]);
  });
});

/** A Hermes whose turns finish only when the test says so, recording how many ran at once. */
function gatedHermes() {
  const state = { running: 0, peak: 0, started: [] as string[] };
  const gates: Array<() => void> = [];
  const calls: FakeDestination["calls"] = [];
  const destination: FakeDestination = {
    calls,
    async deliver(params) {
      calls.push(params);
      const { memoId, threadId } = params;
      state.started.push(memoId);
      state.running++;
      state.peak = Math.max(state.peak, state.running);
      await new Promise<void>((release) => gates.push(release));
      state.running--;
      return { ref: threadId ?? memoId, replyText: "ok" };
    },
  };
  return { state, gates, destination };
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 5));

function twoTurns(threads: [string, string]) {
  const hermes = gatedHermes();
  const ctx = setup({ destination: hermes.destination });
  const memos = threads.map((threadId, i) => {
    ctx.db
      .query(
        "INSERT OR IGNORE INTO threads (id, kind, title, created_at, updated_at) VALUES (?, 'hermes', 'earlier', 'c', 'u')",
      )
      .run(threadId);
    const { memo } = ctx.store.createTextMemo({
      id: crypto.randomUUID(),
      mode: "auto",
      device: "iphone",
      startedAt: "2026-01-01T00:00:00.000Z",
      text: `turn ${i}`,
      threadId,
    });
    return memo;
  });
  return { ...hermes, handlers: ctx.handlers, memos };
}

describe("a memo that continues a thread", () => {
  const THREAD = "0b1f6c52-4a7d-4e90-8c13-9d2a5e7f1b34";

  /** A text memo created in `THREAD`, with the thread row the earlier turn left behind. */
  function continuing(mode: "chat" | "auto" = "auto") {
    const ctx = setup();
    ctx.db
      .query(
        "INSERT INTO threads (id, kind, title, created_at, updated_at) VALUES (?, 'hermes', 'earlier', 'c', 'u')",
      )
      .run(THREAD);
    const { memo } = ctx.store.createTextMemo({
      id: crypto.randomUUID(),
      mode,
      device: "iphone",
      startedAt: "2026-01-01T00:00:00.000Z",
      text: "and then?",
      threadId: THREAD,
    });
    return { ...ctx, memo };
  }

  it("delivers into the thread's session with the memo's mode", async () => {
    const { handlers, destination, memo } = continuing("chat");
    const result = await handlers.act?.({ memo });
    expect(destination.calls).toEqual([
      { memoId: memo.id, transcript: "and then?", mode: "chat", threadId: THREAD },
    ]);
    expect(result?.patch).toMatchObject({
      destinationRef: THREAD,
      thread: { id: THREAD, kind: "hermes" },
      kind: "note",
    });
  });

  it("sends no thread for a memo whose thread is its own session", async () => {
    const { store, handlers, destination } = setup();
    const memo = { ...seedMemo(store, "transcribed"), transcript: "again" };
    await handlers.act?.({ memo: { ...memo, threadId: memo.id } });
    expect(destination.calls).toEqual([{ memoId: memo.id, transcript: "again", mode: "auto" }]);
  });

  describe("turns into one session", () => {
    it("makes the second memo of a thread wait for the first, without failing it", async () => {
      const { handlers, memos, state, gates } = twoTurns([THREAD, THREAD]);
      const ids = memos.map((memo) => memo.id);
      const [first, second] = memos.map((memo) => handlers.act?.({ memo })) as [
        Promise<unknown>,
        Promise<unknown>,
      ];
      await tick();
      expect(state.started).toEqual(ids.slice(0, 1));

      gates[0]?.();
      await first;
      await tick();
      expect(state.started).toEqual(ids);

      gates[1]?.();
      await expect(second).resolves.toMatchObject({ patch: { destinationRef: THREAD } });
      expect(state.peak).toBe(1);
    });

    it("hands only the wait behind another turn to the runner's whileWaiting", async () => {
      const { handlers, memos, gates } = twoTurns([THREAD, THREAD]);
      let waits = 0;
      const whileWaiting = <T>(wait: Promise<T>) => {
        waits++;
        return wait;
      };
      const [first, second] = memos.map((memo) => handlers.act?.({ memo, whileWaiting })) as [
        Promise<unknown>,
        Promise<unknown>,
      ];
      await tick();
      expect(waits).toBe(1);
      gates[0]?.();
      await first;
      await tick();
      gates[1]?.();
      await second;
    });

    it("does not make different threads wait for each other", async () => {
      const { handlers, memos, state, gates } = twoTurns([THREAD, "other-thread"]);
      const running = memos.map((memo) => handlers.act?.({ memo }));
      await tick();
      expect(state.peak).toBe(2);
      for (const gate of gates) gate();
      await Promise.all(running);
    });
  });
});
