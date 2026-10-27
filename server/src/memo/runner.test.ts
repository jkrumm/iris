import { describe, expect, it } from "bun:test";
import { MemoError } from "./errors.js";
import { createMemoEvents, type MemoEvent } from "./events.js";
import type { HandlerStep } from "./memo.js";
import { createRunner, type StepHandler } from "./runner.js";
import { deferred, seedMemo, testStore } from "./test-support.js";

const STEPS: HandlerStep[] = ["transcribe", "route", "act", "summarize", "notify"];

function setup(overrides: Partial<Record<HandlerStep, StepHandler>> = {}) {
  const { store, clock } = testStore();
  const events = createMemoEvents();
  const emitted: MemoEvent[] = [];
  events.subscribe((e) => emitted.push(e));
  const calls: HandlerStep[] = [];
  const handlers: Partial<Record<HandlerStep, StepHandler>> = {};
  for (const step of STEPS) {
    handlers[step] =
      overrides[step] ??
      (async () => {
        calls.push(step);
        return {};
      });
  }
  const runner = createRunner({ store, handlers, events, clock });
  return { store, clock, events, emitted, calls, handlers, runner };
}

describe("drive", () => {
  it("runs a received memo to notified, recording the timeline and an event per step", async () => {
    const { store, runner, calls, emitted } = setup({
      transcribe: async () => ({ usage: { seconds: 12 }, costUsd: 0.02 }),
    });
    const { id } = seedMemo(store, "received");
    await runner.drive(id);

    expect(store.getMemo(id)?.state).toBe("notified");
    expect(calls).toEqual(["route", "act", "summarize", "notify"]);
    const steps = store.listStepRecords(id);
    expect(steps.map((s) => [s.step, s.status])).toEqual([
      ["transcribe", "done"],
      ["route", "done"],
      ["act", "done"],
      ["summarize", "done"],
      ["notify", "done"],
    ]);
    expect(steps[0]).toMatchObject({ usage: { seconds: 12 }, costUsd: 0.02 });
    expect(emitted.map((e) => [e.step, e.state])).toEqual([
      ["transcribe", "transcribed"],
      ["route", "routed"],
      ["act", "acted"],
      ["summarize", "summarized"],
      ["notify", "notified"],
    ]);
  });

  it("does nothing for a receiving memo, an unknown id, or a finished memo", async () => {
    const { store, runner, calls } = setup();
    await runner.drive(seedMemo(store, "receiving").id);
    await runner.drive("unknown");
    await runner.drive(seedMemo(store, "notified").id);
    expect(calls).toEqual([]);
  });

  it("fails the memo at the throwing step and stops", async () => {
    const { store, runner, calls, emitted } = setup({
      act: async () => {
        throw new Error("hermes down");
      },
    });
    const { id } = seedMemo(store, "received");
    await runner.drive(id);

    expect(store.getMemo(id)).toMatchObject({
      state: "failed",
      failedStep: "act",
      error: "hermes down",
    });
    expect(calls).toEqual(["transcribe", "route"]);
    expect(store.listStepRecords(id).at(-1)).toMatchObject({
      step: "act",
      status: "failed",
      error: "hermes down",
    });
    expect(emitted.at(-1)).toMatchObject({ state: "failed", step: "act", failedStep: "act" });
  });

  it("parks without error when the next step has no handler", async () => {
    const { store, clock, events } = setup();
    const runner = createRunner({
      store,
      handlers: { transcribe: async () => ({}) },
      events,
      clock,
    });
    const { id } = seedMemo(store, "received");
    await runner.drive(id);
    expect(store.getMemo(id)?.state).toBe("transcribed");
    await runner.drive(id);
    expect(store.getMemo(id)?.state).toBe("transcribed");
  });

  it("parks a memo the router could not place and does not advance it", async () => {
    const { store, runner, calls } = setup({ route: async () => ({ outcome: "needs_route" }) });
    const { id } = seedMemo(store, "received");
    await runner.drive(id);
    expect(store.getMemo(id)?.state).toBe("needs_route");
    expect(calls).toEqual(["transcribe"]);
    await runner.drive(id);
    expect(store.getMemo(id)?.state).toBe("needs_route");
  });

  it("fails the step when a non-route handler asks to park", async () => {
    const { store, runner } = setup({ act: async () => ({ outcome: "needs_route" }) });
    const { id } = seedMemo(store, "routed");
    await runner.drive(id);
    expect(store.getMemo(id)).toMatchObject({ state: "failed", failedStep: "act" });
  });

  it("is single-flight: concurrent drives share one run and run each handler once", async () => {
    const gate = deferred();
    let transcribed = 0;
    const { store, runner, calls } = setup({
      transcribe: async () => {
        transcribed++;
        await gate.promise;
        return {};
      },
    });
    const { id } = seedMemo(store, "received");
    const first = runner.drive(id);
    const second = runner.drive(id);
    expect(second).toBe(first);
    gate.resolve();
    await Promise.all([first, second]);

    expect(transcribed).toBe(1);
    expect(calls).toEqual(["route", "act", "summarize", "notify"]);
    expect(store.getMemo(id)?.state).toBe("notified");
  });

  it("starts a fresh run once the previous one has settled", async () => {
    const { store, runner, calls } = setup();
    const { id } = seedMemo(store, "received");
    await runner.drive(id);
    await runner.drive(id);
    expect(calls).toEqual(["transcribe", "route", "act", "summarize", "notify"]);
  });
});

describe("driveAll", () => {
  it("resumes memos left mid-pipeline, re-running the step that was running at the crash", async () => {
    const { store, runner, calls } = setup();
    const received = seedMemo(store, "received");
    const crashed = seedMemo(store, "routed");
    store.markStepStarted({ id: crashed.id, step: "act" });
    const done = seedMemo(store, "notified");
    const uploading = seedMemo(store, "receiving");

    await runner.driveAll();

    expect(store.getMemo(received.id)?.state).toBe("notified");
    expect(store.getMemo(crashed.id)?.state).toBe("notified");
    expect(store.getMemo(done.id)?.state).toBe("notified");
    expect(store.getMemo(uploading.id)?.state).toBe("receiving");
    expect(calls.filter((s) => s === "act")).toHaveLength(2);
    expect(store.listStepRecords(crashed.id).find((s) => s.step === "act")?.status).toBe("done");
    expect(calls.filter((s) => s === "transcribe")).toHaveLength(1);
  });
});

function failedAt(failStep: HandlerStep) {
  let fail = true;
  const ctx = setup({
    [failStep]: async () => {
      if (fail) throw new Error("boom");
      return {};
    },
  });
  const { id } = seedMemo(ctx.store, "received");
  return { ...ctx, id, heal: () => (fail = false) };
}

function codeOf(fn: () => unknown) {
  try {
    fn();
  } catch (err) {
    return err instanceof MemoError ? err.code : "other";
  }
  return "none";
}

describe("retry", () => {
  it("resets from the failed step, clears the error and completes", async () => {
    const { store, runner, id, heal, emitted } = failedAt("summarize");
    await runner.drive(id);
    expect(store.getMemo(id)?.state).toBe("failed");

    heal();
    const reset = runner.retry({ id, from: "summarize" });
    expect(reset).toMatchObject({ state: "acted", failedStep: null, error: null });
    expect(emitted.at(-1)).toMatchObject({ state: "acted", step: null });
    await runner.drive(id);

    expect(store.getMemo(id)?.state).toBe("notified");
    expect(store.listStepRecords(id).every((s) => s.status === "done")).toBe(true);
  });

  it("can rewind to an earlier step and re-runs everything from there", async () => {
    const { store, runner, id, heal, calls } = failedAt("act");
    await runner.drive(id);
    heal();
    calls.length = 0;
    runner.retry({ id, from: "transcribe" });
    await runner.drive(id);
    expect(store.getMemo(id)?.state).toBe("notified");
    expect(calls).toEqual(["transcribe", "route", "summarize", "notify"]);
  });

  it("rejects a retry that is not from a failed memo, or from an invalid step", async () => {
    const { store, runner, id } = failedAt("route");
    await runner.drive(id);

    const code = codeOf;
    expect(code(() => runner.retry({ id, from: "ingest" }))).toBe("bad_request");
    expect(code(() => runner.retry({ id, from: "act" }))).toBe("bad_request");
    expect(code(() => runner.retry({ id, from: "bogus" as never }))).toBe("bad_request");
    expect(code(() => runner.retry({ id: "unknown", from: "route" }))).toBe("not_found");
    expect(code(() => runner.retry({ id: seedMemo(store, "acted").id, from: "act" }))).toBe(
      "bad_state",
    );
    expect(store.getMemo(id)?.state).toBe("failed");
  });
});
