import { describe, expect, it } from "bun:test";
import { createMemoEvents } from "../memo/events.js";
import { createRunner } from "../memo/runner.js";
import { fakeAudio, seedMemo, testStore } from "../memo/test-support.js";
import type { Destinations } from "../ports/destination.js";
import {
  fakeDecider,
  fakeDestination,
  fakeNotifier,
  fakeSummarizer,
  fakeTranscriber,
} from "../ports/fakes.js";
import { createStepHandlers } from "./steps.js";

function setup(
  options: {
    transcriber?: ReturnType<typeof fakeTranscriber>;
    destination?: ReturnType<typeof fakeDestination>;
    /** Replaces the Hermes-only registry, e.g. to add a journal destination. */
    destinations?: Destinations;
    decider?: ReturnType<typeof fakeDecider>;
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
    destinations: options.destinations ?? { hermes: destination },
    decider: options.decider,
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
      destinations: { hermes: fakeDestination() },
      notifier: fakeNotifier(),
    });
    expect(Object.keys(handlers).toSorted()).toEqual(["act", "notify", "route"]);
  });

  it("registers neither route nor act without a destination", () => {
    const { store } = testStore();
    const handlers = createStepHandlers({ store, audio: fakeAudio(), notifier: fakeNotifier() });
    expect(Object.keys(handlers)).toEqual(["notify"]);
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

const transcribed = (store: ReturnType<typeof testStore>["store"], transcript = "kauf Milch") => ({
  ...seedMemo(store, "transcribed"),
  transcript,
});

describe("route", () => {
  it("routes to the only registered destination as the default, with no cost", async () => {
    const { store, handlers } = setup();
    const result = await handlers.route?.({ memo: transcribed(store) });
    expect(result).toEqual({
      patch: {
        route: "hermes",
        routeDecision: {
          source: "default",
          destination: "hermes",
          tab: null,
          confidence: 1,
          model: null,
          costUsd: null,
          reason: null,
          outcome: "routed",
        },
      },
    });
  });

  it("routes by a spoken prefix without rewriting the transcript", async () => {
    const { store, handlers } = setup({
      destinations: { hermes: fakeDestination(), journal: fakeDestination() },
    });
    const result = await handlers.route?.({ memo: transcribed(store, "Tagebuch: heute war gut") });
    expect(result).toMatchObject({
      patch: {
        route: "journal",
        routeDecision: { source: "prefix", destination: "journal", outcome: "routed" },
      },
    });
    expect(result?.outcome).toBeUndefined();
    expect(result?.patch).not.toHaveProperty("transcript");
  });

  it("parks on a destination that is not registered, leaving route unset", async () => {
    const { store, handlers } = setup();
    const result = await handlers.route?.({ memo: transcribed(store, "Tagebuch: heute war gut") });
    expect(result?.outcome).toBe("needs_route");
    expect(result?.patch).toEqual({
      routeDecision: {
        source: "prefix",
        destination: null,
        tab: null,
        confidence: null,
        model: null,
        costUsd: null,
        reason: "journal not available",
        outcome: "needs_route",
      },
    });
  });

  it("carries the decide cost and usage on the step result", async () => {
    const decider = fakeDecider({
      result: {
        destination: { choice: "journal", confidence: 0.92 },
        model: "decider-1",
        costUsd: 0.0004,
        usage: { inputTokens: 90 },
      },
    });
    const { store, handlers } = setup({
      decider,
      destinations: { hermes: fakeDestination(), journal: fakeDestination() },
    });
    const result = await handlers.route?.({ memo: transcribed(store) });
    expect(result).toMatchObject({
      patch: {
        route: "journal",
        routeDecision: {
          source: "decide",
          destination: "journal",
          confidence: 0.92,
          model: "decider-1",
          costUsd: 0.0004,
        },
      },
      usage: { inputTokens: 90 },
      costUsd: 0.0004,
    });
    expect(result?.patch).not.toHaveProperty("transcript");
  });

  it("throws without a transcript", async () => {
    const { store, handlers } = setup();
    await expect(handlers.route?.({ memo: seedMemo(store, "transcribed") })).rejects.toThrow(
      "no transcript",
    );
  });
});

describe("act", () => {
  it("delivers the transcript and patches the ref and reply", async () => {
    const { store, handlers, destination } = setup();
    const memo = { ...seedMemo(store, "routed"), transcript: "do the thing", route: "hermes" };
    const result = await handlers.act?.({ memo });
    expect(destination.calls).toEqual([{ memoId: memo.id, transcript: "do the thing" }]);
    expect(result).toEqual({
      patch: { destinationRef: "session-1", replyText: "done" },
      usage: { turns: 1 },
      costUsd: 0.1,
    });
  });

  it("dispatches by the memo's route", async () => {
    const hermes = fakeDestination();
    const journal = fakeDestination({ result: { ref: "note.md", replyText: "" } });
    const { store, handlers } = setup({ destinations: { hermes, journal } });
    const memo = { ...seedMemo(store, "routed"), transcript: "heute", route: "journal" };
    const result = await handlers.act?.({ memo });
    expect(hermes.calls).toEqual([]);
    expect(journal.calls).toEqual([{ memoId: memo.id, transcript: "heute" }]);
    expect(result).toMatchObject({ patch: { destinationRef: "note.md" } });
  });

  it("throws when the route has no registered destination", async () => {
    const { store, handlers } = setup();
    const memo = { ...seedMemo(store, "routed"), transcript: "t", route: "journal" };
    await expect(handlers.act?.({ memo })).rejects.toThrow(
      'no destination registered for route "journal"',
    );
    await expect(handlers.act?.({ memo: { ...memo, route: null } })).rejects.toThrow("no route");
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

describe("routing through the runner", () => {
  it("writes the decision row with the step and keeps the raw transcript and delivers the stripped one", async () => {
    const { store, runner, destination, summarizer } = setup({
      transcriber: fakeTranscriber({ result: { text: "Hermes, kauf Milch" } }),
    });
    const { id } = seedWithSegments(store, [0]);
    await runner.drive(id);

    expect(store.getMemo(id)).toMatchObject({
      state: "notified",
      route: "hermes",
      transcript: "Hermes, kauf Milch",
    });
    expect(destination.calls).toEqual([{ memoId: id, transcript: "kauf Milch" }]);
    expect(summarizer.calls[0]?.transcript).toBe("kauf Milch");
    expect(store.listRouteDecisions(id)).toMatchObject([
      { source: "prefix", destination: "hermes", confidence: 1, outcome: "routed" },
    ]);
  });

  it("parks at needs_route with a readable reason and does not act", async () => {
    const { store, runner, destination } = setup({
      transcriber: fakeTranscriber({ result: { text: "Tagebuch: heute war gut" } }),
    });
    const { id } = seedWithSegments(store, [0]);
    await runner.drive(id);

    expect(store.getMemo(id)).toMatchObject({
      state: "needs_route",
      route: null,
      transcript: "Tagebuch: heute war gut",
    });
    expect(store.listRouteDecisions(id).at(-1)).toMatchObject({
      outcome: "needs_route",
      destination: null,
      reason: "journal not available",
    });
    expect(destination.calls).toEqual([]);
  });

  it("records the decide cost and usage on the route step row", async () => {
    const decider = fakeDecider({
      result: {
        destination: { choice: "hermes", confidence: 0.9 },
        costUsd: 0.0004,
        usage: { inputTokens: 90 },
      },
    });
    const { store, runner } = setup({
      decider,
      destinations: { hermes: fakeDestination(), journal: fakeDestination() },
    });
    const { id } = seedWithSegments(store, [0]);
    await runner.drive(id);

    const route = store.listStepRecords(id).find((s) => s.step === "route");
    expect(route).toMatchObject({ usage: { inputTokens: 90 }, costUsd: 0.0004 });
    expect(store.listRouteDecisions(id)).toMatchObject([
      { source: "decide", destination: "hermes", confidence: 0.9, costUsd: 0.0004 },
    ]);
  });

  it("parks as 'decide unavailable' with two destinations and no decider", async () => {
    const { store, runner } = setup({
      destinations: { hermes: fakeDestination(), journal: fakeDestination() },
    });
    const { id } = seedWithSegments(store, [0]);
    await runner.drive(id);
    expect(store.getMemo(id)?.state).toBe("needs_route");
    expect(store.listRouteDecisions(id).at(-1)?.reason).toBe("decide unavailable");
  });

  it("routes a retry from route by the same prefix and still delivers the stripped text", async () => {
    const inner = fakeDestination({ result: { ref: "note.md", replyText: "" } });
    let broken = true;
    const journal = {
      calls: inner.calls,
      async deliver(params: Parameters<typeof inner.deliver>[0]) {
        if (broken) throw new Error("brain locked");
        return inner.deliver(params);
      },
    };
    const { store, runner } = setup({
      transcriber: fakeTranscriber({ result: { text: "Tagebuch: heute war gut" } }),
      destinations: { hermes: fakeDestination(), journal },
    });
    const { id } = seedWithSegments(store, [0]);
    await runner.drive(id);
    expect(store.getMemo(id)).toMatchObject({ state: "failed", failedStep: "act" });

    broken = false;
    runner.retry({ id, from: "route" });
    await runner.idle();

    expect(store.getMemo(id)).toMatchObject({
      state: "notified",
      route: "journal",
      transcript: "Tagebuch: heute war gut",
    });
    expect(store.listRouteDecisions(id).map((d) => [d.source, d.destination])).toEqual([
      ["prefix", "journal"],
      ["prefix", "journal"],
    ]);
    expect(inner.calls).toEqual([{ memoId: id, transcript: "heute war gut" }]);
  });
});
