import { describe, expect, it } from "bun:test";
import { createMemoEvents } from "../memo/events.js";
import { bindNeedsRouteAlerts } from "../notify/needs-route.js";
import { createRunner } from "../memo/runner.js";
import { captureLogs, fakeAudio, seedMemo, testStore } from "../memo/test-support.js";
import { TabGoneError, type Destination, type Destinations } from "../ports/destination.js";
import {
  fakeDecider,
  fakeDestination,
  fakeHerd,
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
    summarizer?: ReturnType<typeof fakeSummarizer> | null;
    herd?: ReturnType<typeof fakeHerd>;
    notifier?: ReturnType<typeof fakeNotifier>;
  } = {},
) {
  const { store, clock } = testStore();
  const audio = fakeAudio();
  const transcriber = options.transcriber ?? fakeTranscriber({ result: { costUsd: 0.02 } });
  const destination =
    options.destination ?? fakeDestination({ result: { usage: { turns: 1 }, costUsd: 0.1 } });
  const summarizer =
    options.summarizer === null
      ? undefined
      : (options.summarizer ?? fakeSummarizer({ result: { costUsd: 0.001 } }));
  const notifier = options.notifier ?? fakeNotifier();
  const handlers = createStepHandlers({
    store,
    audio,
    transcriber,
    destinations: options.destinations ?? { hermes: destination },
    herd: options.herd,
    decider: options.decider,
    summarizer,
    notifier,
  });
  const events = createMemoEvents();
  const runner = createRunner({ store, handlers, events, clock });
  return { store, audio, handlers, runner, events, transcriber, destination, summarizer, notifier };
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
    expect(Object.keys(handlers).toSorted()).toEqual(["act", "notify", "route", "summarize"]);
  });

  it("registers neither route nor act without a destination", () => {
    const { store } = testStore();
    const handlers = createStepHandlers({ store, audio: fakeAudio(), notifier: fakeNotifier() });
    expect(Object.keys(handlers).toSorted()).toEqual(["notify", "summarize"]);
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
      patch: {
        destinationRef: "session-1",
        replyText: "done",
        thread: { id: "session-1", kind: "hermes", title: "do the thing" },
      },
      usage: { turns: 1 },
      costUsd: 0.1,
    });
  });

  it("tells the destination a chat memo is a chat and persists the thread it names", async () => {
    const { store, handlers, destination } = setup();
    const memo = {
      ...seedMemo(store, "routed"),
      mode: "chat" as const,
      transcript: "what is   a monad?",
      route: "hermes",
    };
    const result = await handlers.act?.({ memo });
    expect(destination.calls).toEqual([
      { memoId: memo.id, transcript: "what is   a monad?", chat: true },
    ]);
    expect(result).toMatchObject({
      patch: { thread: { id: "session-1", kind: "chat", title: "what is a monad?" } },
    });
  });

  it("persists the thread exactly as the destination reported it", async () => {
    const thread = { id: "other", kind: "hermes" as const, title: "named by the adapter" };
    const { store, handlers } = setup({ destination: fakeDestination({ result: { thread } }) });
    const memo = { ...seedMemo(store, "routed"), transcript: "anything", route: "hermes" };
    const result = await handlers.act?.({ memo });
    expect(result?.patch?.thread).toEqual(thread);
  });

  it("persists no thread when the destination reports none", async () => {
    const journal = fakeDestination({ threads: false, result: { ref: "note.md", replyText: "" } });
    const { store, handlers } = setup({ destinations: { hermes: fakeDestination(), journal } });
    const memo = { ...seedMemo(store, "routed"), transcript: "heute", route: "journal" };
    const result = await handlers.act?.({ memo });
    expect(result?.patch).toEqual({ destinationRef: "note.md", replyText: "" });
  });

  it("dispatches by the memo's route", async () => {
    const hermes = fakeDestination();
    const journal = fakeDestination({ threads: false, result: { ref: "note.md", replyText: "" } });
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
    expect(summarizer?.calls).toEqual([
      { memoId: memo.id, route: "hermes", transcript: "t", replyText: "r" },
    ]);
    expect(result).toMatchObject({
      patch: { summary: { headline: "Headline", detail: "Detail", spoken: "Spoken." } },
      costUsd: 0.001,
    });
  });
});

describe("summarize: templated routes", () => {
  const herd = fakeHerd({
    tabs: [{ id: "w1:t1", repo: "iris", label: "server", agentState: "idle", lastActivity: null }],
  });

  it("summarizes a journal memo without a summarizer, with no cost", async () => {
    const { store, handlers } = setup({ summarizer: null });
    const memo = {
      ...seedMemo(store, "acted"),
      route: "journal",
      transcript: "heute\n war   gut",
    };
    expect(await handlers.summarize?.({ memo })).toEqual({
      patch: {
        summary: {
          headline: "Saved to journal",
          detail: "heute war gut",
          spoken: "Saved to your journal.",
        },
      },
    });
  });

  it("summarizes a herdr memo with the tab it went to, without calling the summarizer", async () => {
    const { store, handlers, summarizer } = setup({ herd });
    const memo = {
      ...seedMemo(store, "acted"),
      route: "herdr",
      destinationRef: "w1:t1",
      transcript: "run the tests",
    };
    expect(await handlers.summarize?.({ memo })).toEqual({
      patch: {
        summary: {
          headline: "Sent to iris / server",
          detail: "run the tests",
          spoken: "Sent to iris server.",
        },
      },
    });
    expect(summarizer?.calls).toEqual([]);
  });

  it("falls back to a generic target when the tab is no longer in the herd", async () => {
    for (const unreadable of [
      setup({ herd: fakeHerd({ failWith: new Error("down") }) }),
      setup(),
    ]) {
      const memo = {
        ...seedMemo(unreadable.store, "acted"),
        route: "herdr",
        destinationRef: "w9:t9",
        transcript: "x",
      };
      const result = await unreadable.handlers.summarize?.({ memo });
      expect(result?.patch?.summary).toMatchObject({
        headline: "Sent to tab",
        spoken: "Sent to the tab.",
      });
    }
  });

  it("keeps the headline within 60 and the detail within 240 characters", async () => {
    const long = fakeHerd({
      tabs: [
        {
          id: "w1:t1",
          repo: "r".repeat(50),
          label: "l".repeat(50),
          agentState: "idle",
          lastActivity: null,
        },
      ],
    });
    const { store, handlers } = setup({ herd: long });
    const memo = {
      ...seedMemo(store, "acted"),
      route: "herdr",
      destinationRef: "w1:t1",
      transcript: "word ".repeat(100),
    };
    const summary = (await handlers.summarize?.({ memo }))?.patch?.summary;
    expect(summary?.headline.length).toBeLessThanOrEqual(60);
    expect(summary?.detail.length).toBeLessThanOrEqual(240);
    expect(summary?.detail.endsWith("…")).toBe(true);
  });

  it("logs when the herd cannot be read for the tab name", async () => {
    const { store, handlers } = setup({ herd: fakeHerd({ failWith: new Error("down") }) });
    const memo = {
      ...seedMemo(store, "acted"),
      route: "herdr",
      destinationRef: "w1:t1",
      transcript: "x",
    };
    const { lines } = await captureLogs(async () => {
      await handlers.summarize?.({ memo });
    });
    expect(lines).toContainEqual(
      expect.objectContaining({
        event: "summarize.herd_unavailable",
        memo: memo.id,
        error: "down",
      }),
    );
  });

  it("strips a spoken prefix from the excerpt", async () => {
    const { store, handlers } = setup({ summarizer: null });
    const memo = {
      ...seedMemo(store, "acted"),
      route: "journal",
      transcript: "Tagebuch: heute war gut",
    };
    store.completeStep({
      id: memo.id,
      step: "route",
      from: "acted",
      to: "acted",
      patch: {
        routeDecision: {
          source: "prefix",
          destination: "journal",
          tab: null,
          confidence: 1,
          model: null,
          costUsd: null,
          reason: null,
          outcome: "routed",
        },
      },
    });
    const result = await handlers.summarize?.({ memo });
    expect(result?.patch?.summary?.detail).toBe("heute war gut");
  });

  it("still needs a summarizer for hermes", async () => {
    const { store, handlers } = setup({ summarizer: null });
    const memo = { ...seedMemo(store, "acted"), route: "hermes", transcript: "t" };
    await expect(handlers.summarize?.({ memo })).rejects.toThrow("no summarizer configured");
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
    expect(summarizer?.calls[0]?.transcript).toBe("kauf Milch");
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

  it("fails the step on a decider failure and recovers with a retry from route", async () => {
    const inner = fakeDecider({ result: { destination: { choice: "journal", confidence: 0.95 } } });
    let broken = true;
    const decider = {
      calls: inner.calls,
      async decide(params: Parameters<typeof inner.decide>[0]) {
        if (broken) throw new Error("agw decide timed out after 1800000 ms");
        return inner.decide(params);
      },
    };
    const { store, runner } = setup({
      decider,
      destinations: { hermes: fakeDestination(), journal: fakeDestination() },
    });
    const { id } = seedWithSegments(store, [0]);
    await runner.drive(id);

    expect(store.getMemo(id)).toMatchObject({
      state: "failed",
      failedStep: "route",
      error: "agw decide timed out after 1800000 ms",
      route: null,
    });
    expect(store.listRouteDecisions(id)).toEqual([]);

    broken = false;
    runner.retry({ id, from: "route" });
    await runner.idle();
    expect(store.getMemo(id)).toMatchObject({ state: "notified", route: "journal" });
    expect(store.listRouteDecisions(id)).toMatchObject([{ source: "decide", outcome: "routed" }]);
  });

  it("does not re-run route or reach act when a parked memo is driven again", async () => {
    const decider = fakeDecider({
      result: { destination: { choice: "journal", confidence: 0.5 } },
    });
    const hermes = fakeDestination();
    const journal = fakeDestination();
    const { store, runner } = setup({ decider, destinations: { hermes, journal } });
    const { id } = seedWithSegments(store, [0]);
    await runner.drive(id);
    expect(store.getMemo(id)?.state).toBe("needs_route");

    await runner.drive(id);
    await runner.driveAll();

    expect(store.getMemo(id)?.state).toBe("needs_route");
    expect(decider.calls).toHaveLength(1);
    expect(store.listRouteDecisions(id)).toHaveLength(1);
    expect([hermes.calls, journal.calls]).toEqual([[], []]);
  });
});

const spoken = (text: string) => fakeTranscriber({ result: { text } });

describe("herdr act", () => {
  const herd = fakeHerd({
    tabs: [
      { id: "w1:t1", repo: "iris", label: "server", agentState: "idle", lastActivity: null },
      { id: "w2:t1", repo: "dotfiles", label: "main", agentState: "idle", lastActivity: null },
    ],
  });
  it("delivers the stripped transcript to the tab the prefix resolved to", async () => {
    const herdr = fakeDestination({ result: { ref: "w1:t1", replyText: "" } });
    const { store, runner, summarizer } = setup({
      transcriber: spoken("Tab server run the tests"),
      destinations: { herdr, hermes: fakeDestination() },
      herd,
    });
    const { id } = seedWithSegments(store, [0]);
    await runner.drive(id);

    expect(herdr.calls).toEqual([{ memoId: id, transcript: "run the tests", tab: "w1:t1" }]);
    expect(store.getMemo(id)).toMatchObject({
      state: "notified",
      route: "herdr",
      destinationRef: "w1:t1",
      summary: { headline: "Sent to iris / server", detail: "run the tests" },
    });
    expect(summarizer?.calls).toEqual([]);
  });

  it("passes no tab to a destination that is not herdr", async () => {
    const hermes = fakeDestination();
    const { store, runner } = setup({ destinations: { hermes } });
    const { id } = seedWithSegments(store, [0]);
    await runner.drive(id);
    expect(hermes.calls[0]).toEqual({ memoId: id, transcript: "hello iris" });
  });

  it("parks a herdr route that names no tab instead of failing the step", async () => {
    const herdr = fakeDestination();
    const { store, handlers } = setup({ destinations: { herdr } });
    const memo = { ...seedMemo(store, "routed"), transcript: "t", route: "herdr" };
    const result = await handlers.act?.({ memo });
    expect(herdr.calls).toEqual([]);
    expect(result).toEqual({
      outcome: "needs_route",
      patch: {
        routeDecision: {
          source: "default",
          outcome: "needs_route",
          destination: "herdr",
          tab: null,
          confidence: null,
          model: null,
          costUsd: null,
          reason: "which tab?",
        },
      },
    });
  });

  it("with herdr as the only destination routes to the one live tab, or parks at route", async () => {
    const one = fakeHerd({
      tabs: [
        { id: "w1:t1", repo: "iris", label: "server", agentState: "idle", lastActivity: null },
      ],
    });
    const herdr = fakeDestination();
    const a = setup({ destinations: { herdr }, herd: one });
    const first = seedWithSegments(a.store, [0]);
    await a.runner.drive(first.id);
    expect(herdr.calls).toEqual([{ memoId: first.id, transcript: "hello iris", tab: "w1:t1" }]);

    const b = setup({ destinations: { herdr: fakeDestination() }, herd });
    const second = seedWithSegments(b.store, [0]);
    await b.runner.drive(second.id);
    expect(b.store.getMemo(second.id)).toMatchObject({
      state: "needs_route",
      routeReason: "which tab?",
    });
  });

  it("parks a vanished tab, alerts once, and delivers after the answer names another tab", async () => {
    const calls: { memoId: string; transcript: string; tab?: string }[] = [];
    const herdr: Destination = {
      async deliver(params) {
        calls.push(params);
        if (params.tab === "w1:t1") throw new TabGoneError(params.tab);
        return { ref: params.tab ?? "", replyText: "" };
      },
    };
    const { store, runner, events, notifier } = setup({
      transcriber: spoken("Tab server run the tests"),
      destinations: { herdr },
      herd,
    });
    const alerts = bindNeedsRouteAlerts({ events, store, notifier });
    const { id } = seedWithSegments(store, [0]);
    await runner.drive(id);
    await alerts.idle();

    expect(store.getMemo(id)).toMatchObject({
      state: "needs_route",
      route: "herdr",
      routeReason: "tab w1:t1 is gone",
      routeSuggestion: "herdr",
    });
    expect(store.listRouteDecisions(id)).toMatchObject([
      { source: "prefix", outcome: "routed", destination: "herdr", tab: "w1:t1" },
      {
        source: "prefix",
        outcome: "needs_route",
        destination: "herdr",
        tab: "w1:t1",
        reason: "tab w1:t1 is gone",
      },
    ]);
    expect(notifier.needsRouteCalls).toMatchObject([{ reason: "tab w1:t1 is gone" }]);

    // The runner leaves it parked, and the answer routes it as usual.
    await runner.drive(id);
    expect(calls).toHaveLength(1);
    const answered = store.answerRoute({
      id,
      decision: {
        source: "answer",
        destination: "herdr",
        tab: "w2:t1",
        confidence: 1,
        model: null,
        costUsd: null,
        reason: null,
        outcome: "routed",
      },
    });
    expect(answered).toBe(true);
    await runner.drive(id);

    expect(calls.map((c) => c.tab)).toEqual(["w1:t1", "w2:t1"]);
    expect(store.getMemo(id)).toMatchObject({ state: "notified", destinationRef: "w2:t1" });
  });

  it("does not park on any other delivery failure", async () => {
    const herdr = fakeDestination({ failWith: new Error("herdr: socket closed") });
    const { store, runner } = setup({
      transcriber: spoken("Tab server run the tests"),
      destinations: { herdr },
      herd,
    });
    const { id } = seedWithSegments(store, [0]);
    await runner.drive(id);
    expect(store.getMemo(id)).toMatchObject({ state: "failed", failedStep: "act" });
  });
});
