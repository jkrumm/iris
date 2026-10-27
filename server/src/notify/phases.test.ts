import { describe, expect, it } from "bun:test";
import { createSqliteDeviceStore } from "../adapters/sqlite-devices.js";
import { createMemoEvents, memoEvent } from "../memo/events.js";
import type { Memo, Step } from "../memo/memo.js";
import { captureLogs, deferred, seedMemo, testStore } from "../memo/test-support.js";
import { fakeNotifier } from "../ports/fakes.js";
import { bindPhaseUpdates } from "./phases.js";

function setup(options: { withToken?: boolean } = {}) {
  const { db, clock, store } = testStore();
  const devices = createSqliteDeviceStore({ db, clock });
  const events = createMemoEvents();
  const notifier = fakeNotifier();
  const memo = seedMemo(store, "received");
  if (options.withToken ?? true) devices.setActivityToken({ memoId: memo.id, token: "aa11" });
  const binding = bindPhaseUpdates({ events, store, devices, notifier });
  const emit = (to: Memo["state"], step: Step | null = null) => {
    const current = store.getMemo(memo.id) as Memo;
    store.transition({ id: memo.id, from: current.state, to });
    events.publish(memoEvent({ memo: store.getMemo(memo.id) as Memo, step, clock }));
  };
  return { store, devices, events, notifier, memo, binding, emit };
}

describe("bindPhaseUpdates", () => {
  it("sends the memo's current state for a state change", async () => {
    const { notifier, binding, emit } = setup();
    emit("transcribed", "transcribe");
    await binding.idle();
    expect(notifier.phaseCalls.map((c) => c.memo.state)).toEqual(["transcribed"]);
  });

  it("sends no update for a flag change", async () => {
    const { notifier, binding, events, store, memo, emit } = setup();
    emit("transcribed", "transcribe");
    await binding.idle();
    notifier.phaseCalls.length = 0;
    const clock = { now: () => new Date() };
    events.publish(
      memoEvent({ memo: store.getMemo(memo.id) as Memo, step: null, clock, flagChange: true }),
    );
    await binding.idle();
    expect(notifier.phaseCalls).toEqual([]);
  });

  it("skips memos without an activity token", async () => {
    const { notifier, binding, emit } = setup({ withToken: false });
    emit("transcribed", "transcribe");
    await binding.idle();
    expect(notifier.phaseCalls).toEqual([]);
  });

  it("skips receiving and notified", async () => {
    const { notifier, binding, events, store, memo, emit } = setup();
    const clock = { now: () => new Date() };
    events.publish(memoEvent({ memo: { ...memo, state: "receiving" }, step: null, clock }));
    emit("transcribed");
    emit("routed");
    emit("acted");
    emit("summarized");
    await binding.idle();
    notifier.phaseCalls.length = 0;

    emit("notified", "notify");
    await binding.idle();
    expect(notifier.phaseCalls).toEqual([]);
    expect(store.getMemo(memo.id)?.state).toBe("notified");
  });

  it("sends needs_route and failed states", async () => {
    const { notifier, store, events, memo, binding, emit } = setup();
    const clock = { now: () => new Date() };
    emit("transcribed");
    store.transition({ id: memo.id, from: "transcribed", to: "needs_route" });
    events.publish(memoEvent({ memo: store.getMemo(memo.id) as Memo, step: "route", clock }));
    await binding.idle();
    store.markStepFailed({ id: memo.id, step: "route", error: "nope" });
    events.publish(memoEvent({ memo: store.getMemo(memo.id) as Memo, step: "route", clock }));
    await binding.idle();
    expect(notifier.phaseCalls.map((c) => c.memo.state)).toEqual([
      "transcribed",
      "needs_route",
      "failed",
    ]);
  });

  it("serialises sends per memo and lets the latest state win", async () => {
    const { notifier, binding, emit } = setup();
    const gate = deferred();
    let running = 0;
    let maxRunning = 0;
    const phase = notifier.phase;
    notifier.phase = async (params) => {
      running++;
      maxRunning = Math.max(maxRunning, running);
      if (notifier.phaseCalls.length === 0) await gate.promise;
      await phase(params);
      running--;
    };

    emit("transcribed");
    emit("routed");
    emit("acted");
    emit("summarized");
    gate.resolve();
    await binding.idle();

    expect(maxRunning).toBe(1);
    // The first send was already underway; the three queued changes collapse into one send of the latest state.
    expect(notifier.phaseCalls.map((c) => c.memo.state)).toEqual(["transcribed", "summarized"]);
  });

  it("logs and survives a throwing notifier, then keeps sending", async () => {
    const { notifier, binding, emit } = setup();
    let first = true;
    const phase = notifier.phase;
    notifier.phase = async (params) => {
      if (first) {
        first = false;
        throw new Error("boom");
      }
      await phase(params);
    };
    const { lines } = await captureLogs(async () => {
      emit("transcribed");
      await binding.idle();
      emit("routed");
      await binding.idle();
    });
    expect(lines.map((l) => l["event"])).toContain("notify.phase_failed");
    expect(notifier.phaseCalls.map((c) => c.memo.state)).toEqual(["routed"]);
  });

  it("stops listening after stop()", async () => {
    const { notifier, binding, emit } = setup();
    binding.stop();
    emit("transcribed");
    await binding.idle();
    expect(notifier.phaseCalls).toEqual([]);
  });
});
