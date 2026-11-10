import { describe, expect, it } from "bun:test";
import { createMemoEvents } from "../memo/events.js";
import { createReplyProgress, type ProgressEvent } from "../memo/progress.js";
import { createRunner } from "../memo/runner.js";
import { fakeAudio, seedMemo, testStore } from "../memo/test-support.js";
import { bindPhaseUpdates } from "../notify/phases.js";
import { fakeDestination, fakeNotifier, fakeSummarizer } from "../ports/fakes.js";
import type { Delivery, Destination } from "../ports/destination.js";
import { createStepHandlers } from "./steps.js";

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

const FENCE = '```iris\n{"kind":"note","headline":"x"}\n```';
const REPLY = "Noted. Two things are done.";

/** Raw deltas as Hermes sends them: a leading "\n\n", text chunks, then the fence split across two deltas. */
const RAW_DELTAS = ["\n\n", "Noted. ", "Two things ", "are done.", "\n\n``", FENCE.slice(2)];

function streamingDestination(opts: { failFirst?: boolean } = {}): Destination & {
  calls: number;
} {
  let calls = 0;
  const inner = fakeDestination();
  return {
    get calls() {
      return calls;
    },
    async deliver(params) {
      calls += 1;
      params.onProgress?.({ type: "tool", tool: "fake_search" });
      if (opts.failFirst && calls === 1) {
        params.onProgress?.({ type: "text", delta: "\n\nhalf" });
        throw new Error("hermes down");
      }
      for (const delta of RAW_DELTAS) {
        params.onProgress?.({ type: "text", delta });
        await sleep(15);
      }
      const delivery: Delivery = await inner.deliver(params);
      return { ...delivery, replyText: REPLY };
    },
  };
}

function setup(destination: Destination) {
  const { store, clock } = testStore();
  const progress = createReplyProgress({ intervalMs: 10 });
  const handlers = createStepHandlers({
    store,
    audio: fakeAudio(),
    destination,
    summarizer: fakeSummarizer(),
    notifier: fakeNotifier(),
    progress,
  });
  const events = createMemoEvents();
  const runner = createRunner({ store, handlers, events, clock });
  const seen: ProgressEvent[] = [];
  progress.subscribe((e) => seen.push(e));
  const memo = seedMemo(store, "transcribed");
  store.completeStep({
    id: memo.id,
    step: "transcribe",
    from: "transcribed",
    to: "transcribed",
    patch: { transcript: "kauf bitte Milch" },
  });
  return { store, progress, events, runner, seen, clock, id: memo.id };
}

const deltasOf = (seen: ProgressEvent[], attempt?: number) =>
  seen.flatMap((e) =>
    e.type === "delta" && (attempt === undefined || e.attempt === attempt) ? [e] : [],
  );

describe("streaming a Hermes turn", () => {
  it("relays ordered deltas that add up to the stored reply and never show the fence", async () => {
    const { store, runner, seen, id, progress } = setup(streamingDestination());
    let midTurn: ReturnType<typeof progress.partial> = null;
    progress.subscribe((e) => {
      if (e.type === "delta" && e.seq === 1) midTurn = progress.partial(id);
    });

    await runner.drive(id);

    const deltas = deltasOf(seen);
    expect(deltas.length).toBeGreaterThanOrEqual(2);
    expect(deltas.map((d) => d.seq)).toEqual(deltas.map((_, i) => i + 1));
    expect(deltas.map((d) => d.text).join("")).toBe(store.getMemo(id)?.replyText ?? "missing");
    expect(store.getMemo(id)?.replyText).toBe(REPLY);
    expect(deltas.some((d) => d.text.includes("```iris"))).toBe(false);
    expect(seen.some((e) => e.type === "activity" && e.tool === "fake_search")).toBe(true);
    expect(midTurn).toMatchObject({ attempt: 1, seq: 1 });
    expect(progress.partial(id)).toBeNull();
  });

  it("a replay of act streams under a higher attempt", async () => {
    const { store, runner, seen, id, progress } = setup(streamingDestination({ failFirst: true }));

    await runner.drive(id);
    expect(store.getMemo(id)).toMatchObject({ state: "failed", failedStep: "act" });
    expect(progress.partial(id)).toBeNull();

    runner.retry({ id, from: "act" });
    await runner.idle();

    expect(
      deltasOf(seen, 1)
        .map((d) => d.text)
        .join(""),
    ).toBe("half");
    const second = deltasOf(seen, 2);
    expect(second.map((d) => d.seq)).toEqual(second.map((_, i) => i + 1));
    expect(second.map((d) => d.text).join("")).toBe(REPLY);
    expect(store.getMemo(id)?.replyText).toBe(REPLY);
  });

  it("a delta triggers no Live Activity phase update", async () => {
    const { store, events, runner, seen, id, progress } = setup(streamingDestination());
    const notifier = fakeNotifier();
    const phases = bindPhaseUpdates({
      events,
      store,
      devices: { getActivityToken: () => "token" } as never,
      notifier,
    });
    // Phase calls as of each progress event: only MemoEvents may move the count, and none fires while the turn streams.
    const phaseCallsAtEvent: number[] = [];
    progress.subscribe(() => phaseCallsAtEvent.push(notifier.phaseCalls.length));

    await runner.drive(id);
    await phases.idle();

    expect(deltasOf(seen).length).toBeGreaterThanOrEqual(2);
    expect(phaseCallsAtEvent.length).toBeGreaterThanOrEqual(3);
    expect(new Set(phaseCallsAtEvent).size).toBe(1);
    phases.stop();
  });
});
