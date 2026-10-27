import { describe, expect, it } from "bun:test";
import { createMemoEvents } from "../memo/events.js";
import { createRunner } from "../memo/runner.js";
import { fakeAudio, seedMemo, testStore } from "../memo/test-support.js";
import { fakeDestination, fakeNotifier, fakeSummarizer, fakeTranscriber } from "../ports/fakes.js";
import { createStepHandlers } from "./steps.js";

function setup(
  options: {
    transcriber?: ReturnType<typeof fakeTranscriber>;
    destination?: ReturnType<typeof fakeDestination>;
    summarizer?: ReturnType<typeof fakeSummarizer>;
    notifier?: ReturnType<typeof fakeNotifier>;
  } = {},
) {
  const { store, clock } = testStore();
  const audio = fakeAudio();
  const transcriber = options.transcriber ?? fakeTranscriber({ result: { costUsd: 0.02 } });
  const destination =
    options.destination ?? fakeDestination({ result: { usage: { turns: 1 }, costUsd: 0.1 } });
  const summarizer = options.summarizer ?? fakeSummarizer({ result: { costUsd: 0.001 } });
  const notifier = options.notifier ?? fakeNotifier();
  const handlers = createStepHandlers({
    store,
    audio,
    transcriber,
    destination,
    summarizer,
    notifier,
  });
  const runner = createRunner({ store, handlers, events: createMemoEvents(), clock });
  return { store, audio, handlers, runner, transcriber, destination, summarizer, notifier };
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
      destination: fakeDestination(),
      notifier: fakeNotifier(),
    });
    expect(Object.keys(handlers).toSorted()).toEqual(["act", "notify", "route"]);
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

describe("route", () => {
  it("always routes to hermes without an outcome", async () => {
    const { store, handlers } = setup();
    const result = await handlers.route?.({ memo: seedMemo(store, "transcribed") });
    expect(result).toEqual({ patch: { route: "hermes" } });
  });
});

describe("act", () => {
  it("delivers the transcript and patches the ref and reply", async () => {
    const { store, handlers, destination } = setup();
    const memo = { ...seedMemo(store, "routed"), transcript: "do the thing" };
    const result = await handlers.act?.({ memo });
    expect(destination.calls).toEqual([{ memoId: memo.id, transcript: "do the thing" }]);
    expect(result).toEqual({
      patch: { destinationRef: "session-1", replyText: "done" },
      usage: { turns: 1 },
      costUsd: 0.1,
    });
  });

  it("throws without a transcript", async () => {
    const { store, handlers, destination } = setup();
    await expect(handlers.act?.({ memo: seedMemo(store, "routed") })).rejects.toThrow(
      "no transcript",
    );
    expect(destination.calls).toEqual([]);
  });
});

describe("summarize", () => {
  it("summarizes with the stored route, transcript and reply", async () => {
    const { store, handlers, summarizer } = setup();
    const memo = {
      ...seedMemo(store, "acted"),
      route: "hermes",
      transcript: "t",
      replyText: "r",
    };
    const result = await handlers.summarize?.({ memo });
    expect(summarizer.calls).toEqual([
      { memoId: memo.id, route: "hermes", transcript: "t", replyText: "r" },
    ]);
    expect(result).toMatchObject({
      patch: { summary: { headline: "Headline", detail: "Detail", spoken: "Spoken." } },
      costUsd: 0.001,
    });
  });
});

describe("notify", () => {
  it("notifies with the memo and its summary", async () => {
    const { store, handlers, notifier } = setup();
    const summary = { headline: "h", detail: "d", spoken: "s" };
    const memo = { ...seedMemo(store, "summarized"), summary };
    expect(await handlers.notify?.({ memo })).toEqual({});
    expect(notifier.calls).toEqual([{ memo, summary }]);
  });

  it("throws when the memo has no summary", async () => {
    const { store, handlers, notifier } = setup();
    await expect(handlers.notify?.({ memo: seedMemo(store, "summarized") })).rejects.toThrow(
      "no summary",
    );
    expect(notifier.calls).toEqual([]);
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
      route: "hermes",
      destinationRef: "session-1",
      replyText: "done",
      summary: { headline: "Headline", detail: "Detail", spoken: "Spoken." },
    });
    expect(store.listStepRecords(id).map((s) => [s.step, s.status, s.usage, s.costUsd])).toEqual([
      ["transcribe", "done", { audioSeconds: 12.5 }, 0.02],
      ["route", "done", null, null],
      ["act", "done", { turns: 1 }, 0.1],
      ["summarize", "done", null, 0.001],
      ["notify", "done", null, null],
    ]);
    expect(notifier.calls).toHaveLength(1);
  });

  it("retries a summarize failure without re-running transcribe", async () => {
    const inner = fakeSummarizer();
    let broken = true;
    const summarizer = {
      calls: inner.calls,
      async summarize(params: Parameters<typeof inner.summarize>[0]) {
        if (broken) throw new Error("agw down");
        return inner.summarize(params);
      },
    };
    const { store, runner, transcriber, destination } = setup({ summarizer });
    const { id } = seedWithSegments(store, [0]);
    await runner.drive(id);
    expect(store.getMemo(id)).toMatchObject({
      state: "failed",
      failedStep: "summarize",
      error: "agw down",
      transcript: "hello iris",
    });

    broken = false;
    runner.retry({ id, from: "summarize" });
    await runner.idle();

    expect(store.getMemo(id)).toMatchObject({
      state: "notified",
      summary: { headline: "Headline" },
    });
    expect(transcriber.calls).toHaveLength(1);
    expect(destination.calls).toHaveLength(1);
    expect(inner.calls).toHaveLength(1);
  });
});
