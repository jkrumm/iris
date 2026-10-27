import { describe, expect, it } from "bun:test";
import { MemoError } from "./errors.js";
import { createMemoEvents, type MemoEvent } from "./events.js";
import type { HandlerStep } from "./memo.js";
import { createRunner, type StepHandler } from "./runner.js";
import { captureLogs, deferred, seedMemo, testStore } from "./test-support.js";

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

describe("atomic completion", () => {
  it("applies the handler's patch together with the state change", async () => {
    const { store, runner } = setup({
      transcribe: async () => ({ patch: { transcript: "hi", audioSeconds: 4 }, costUsd: 0.1 }),
    });
    const { id } = seedMemo(store, "received");
    await runner.drive(id);
    expect(store.getMemo(id)).toMatchObject({ transcript: "hi", audioSeconds: 4 });
    expect(store.listStepRecords(id)[0]).toMatchObject({ status: "done", costUsd: 0.1 });
  });

  it("a lost compare-and-set leaves no done row and no patch", async () => {
    const gate = deferred();
    const started = deferred();
    const { store, runner } = setup({
      transcribe: async () => {
        started.resolve();
        await gate.promise;
        return { patch: { transcript: "late" }, usage: { n: 1 } };
      },
    });
    const { id } = seedMemo(store, "received");
    const running = runner.drive(id);
    await started.promise;
    // Another writer moves the memo while the handler is in flight.
    store.transition({ id, from: "received", to: "transcribed" });
    gate.resolve();
    await running;

    expect(store.getMemo(id)).toMatchObject({ transcript: null });
    expect(store.listStepRecords(id).find((s) => s.step === "transcribe")).toMatchObject({
      status: "running",
      usage: null,
    });
  });

  it("does not record a bookkeeping error as a step failure", async () => {
    const { store, clock, events, handlers } = setup();
    const broken = {
      ...store,
      completeStep() {
        throw new Error("disk full");
      },
    };
    const runner = createRunner({ store: broken, handlers, events, clock });
    const { id } = seedMemo(store, "received");

    const { lines } = await captureLogs(async () => {
      await expect(runner.drive(id)).rejects.toThrow("disk full");
    });
    expect(lines).toContainEqual(
      expect.objectContaining({
        event: "runner.bookkeeping_failed",
        memo_id: id,
        step: "transcribe",
        error: "disk full",
      }),
    );
    expect(store.getMemo(id)).toMatchObject({ state: "received", failedStep: null, error: null });
    expect(store.listStepRecords(id)[0]).toMatchObject({ step: "transcribe", status: "running" });
  });
});

describe("driveAll concurrency", () => {
  it("runs at most three memos at once and finishes them all", async () => {
    const gates = Array.from({ length: 5 }, () => deferred());
    let active = 0;
    let peak = 0;
    let started = 0;
    const { store, runner } = setup({
      transcribe: async () => {
        const gate = gates[started++];
        active++;
        peak = Math.max(peak, active);
        await gate?.promise;
        active--;
        return {};
      },
    });
    const ids = gates.map(() => seedMemo(store, "received").id);

    const all = runner.driveAll();
    await Bun.sleep(0);
    expect(started).toBe(3);
    gates[0]?.resolve();
    gates[1]?.resolve();
    await Bun.sleep(0);
    expect(started).toBe(5);
    for (const gate of gates) gate.resolve();
    await all;

    expect(peak).toBe(3);
    expect(ids.map((id) => store.getMemo(id)?.state)).toEqual(Array(5).fill("notified"));
  });

  it("keeps going when one memo's drive rejects", async () => {
    const { store, clock, events, handlers } = setup();
    const first = seedMemo(store, "received");
    const second = seedMemo(store, "received");
    const flaky = {
      ...store,
      completeStep(params: Parameters<typeof store.completeStep>[0]) {
        if (params.id === first.id) throw new Error("disk full");
        return store.completeStep(params);
      },
    };
    const runner = createRunner({ store: flaky, handlers, events, clock });
    await runner.driveAll();
    expect(store.getMemo(second.id)?.state).toBe("notified");
  });
});

describe("idle", () => {
  it("resolves immediately when nothing is in flight", async () => {
    const { runner } = setup();
    await runner.idle();
  });

  it("waits for every in-flight memo, including a rejected one, and never throws", async () => {
    const gate = deferred();
    const { store, clock, events, handlers } = setup({
      transcribe: async () => {
        await gate.promise;
        return {};
      },
    });
    const broken = {
      ...store,
      completeStep(params: Parameters<typeof store.completeStep>[0]) {
        if (params.step === "route") throw new Error("disk full");
        return store.completeStep(params);
      },
    };
    const runner = createRunner({ store: broken, handlers, events, clock });
    const { id } = seedMemo(store, "received");
    runner.drive(id).catch(() => undefined);

    let idle = false;
    const waiting = runner.idle().then(() => (idle = true));
    await Bun.sleep(0);
    expect(idle).toBe(false);
    gate.resolve();
    await waiting;
    expect(idle).toBe(true);
    expect(store.getMemo(id)?.state).toBe("transcribed");
  });
});

describe("stop", () => {
  it("lets the running step complete but starts no further step", async () => {
    let runnerRef: { stop(): void } | undefined;
    const { store, clock, events, calls } = setup();
    const handlers = {
      transcribe: async () => {
        runnerRef?.stop();
        return { patch: { transcript: "t" } };
      },
      route: async () => {
        calls.push("route");
        return {};
      },
    };
    const runner = createRunner({ store, handlers, events, clock });
    runnerRef = runner;
    const { id } = seedMemo(store, "received");
    await runner.drive(id);

    expect(store.getMemo(id)).toMatchObject({ state: "transcribed", transcript: "t" });
    expect(store.listStepRecords(id).map((s) => [s.step, s.status])).toEqual([
      ["transcribe", "done"],
    ]);
    expect(calls).toEqual([]);
  });

  it("never starts queued driveAll memos or new drives after stop", async () => {
    const gates = Array.from({ length: 3 }, () => deferred());
    let started = 0;
    const { store, runner, calls } = setup({
      transcribe: async () => {
        await gates[started++]?.promise;
        return {};
      },
    });
    const ids = Array.from({ length: 5 }, () => seedMemo(store, "received").id);
    const all = runner.driveAll();
    await Bun.sleep(0);
    expect(started).toBe(3);

    runner.stop();
    for (const gate of gates) gate.resolve();
    await all;
    await runner.drive(ids[4] as string);

    expect(started).toBe(3);
    expect(calls).toEqual([]);
    expect(ids.map((id) => store.getMemo(id)?.state)).toEqual([
      "transcribed",
      "transcribed",
      "transcribed",
      "received",
      "received",
    ]);
  });

  it("idle resolves only after in-flight work and an in-progress driveAll", async () => {
    const gates = Array.from({ length: 4 }, () => deferred());
    let started = 0;
    const { store, runner } = setup({
      transcribe: async () => {
        await gates[started++]?.promise;
        return {};
      },
    });
    for (const _ of gates) seedMemo(store, "received");
    const all = runner.driveAll();
    await Bun.sleep(0);

    let idle = false;
    const waiting = runner.idle().then(() => (idle = true));
    for (const gate of gates.slice(0, 3)) gate.resolve();
    await Bun.sleep(0);
    expect(started).toBe(4);
    expect(idle).toBe(false);
    gates[3]?.resolve();
    await waiting;
    await all;
    expect(store.listNonTerminal()).toEqual([]);
  });
});
