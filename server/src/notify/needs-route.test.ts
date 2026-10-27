import { describe, expect, it } from "bun:test";
import { createMemoEvents, memoEvent } from "../memo/events.js";
import type { Memo, Step } from "../memo/memo.js";
import { captureLogs, deferred, parkMemo, seedMemo, testStore } from "../memo/test-support.js";
import { fakeNotifier } from "../ports/fakes.js";
import { bindNeedsRouteAlerts } from "./needs-route.js";

const settled = (promise: Promise<unknown>) =>
  Promise.race([promise.then(() => true), new Promise<false>((r) => setTimeout(r, 20, false))]);

function setup() {
  const { clock, store } = testStore();
  const events = createMemoEvents();
  const notifier = fakeNotifier();
  const binding = bindNeedsRouteAlerts({ events, store, notifier });
  const publish = (id: string, step: Step | null = "route") =>
    events.publish(memoEvent({ memo: store.getMemo(id) as Memo, step, clock }));
  return { store, events, notifier, binding, publish };
}

describe("bindNeedsRouteAlerts", () => {
  it("sends one alert with the park reason when a memo enters needs_route", async () => {
    const { store, notifier, binding, publish } = setup();
    const id = parkMemo(store, { reason: "journal not available" });
    publish(id);
    await binding.idle();
    expect(notifier.needsRouteCalls).toHaveLength(1);
    expect(notifier.needsRouteCalls[0]).toMatchObject({
      memo: { id, state: "needs_route" },
      reason: "journal not available",
    });
  });

  it("ignores every other state", async () => {
    const { store, notifier, binding, publish } = setup();
    for (const state of ["received", "routed", "acted", "notified", "failed"] as const) {
      publish(seedMemo(store, state === "failed" ? "transcribed" : state).id);
    }
    await binding.idle();
    expect(notifier.needsRouteCalls).toEqual([]);
  });

  it("skips a memo that was answered before the push went out", async () => {
    const { store, notifier, binding, publish } = setup();
    const id = parkMemo(store, { reason: "decide refused" });
    store.transition({ id, from: "needs_route", to: "routed" });
    publish(id);
    await binding.idle();
    expect(notifier.needsRouteCalls).toEqual([]);
  });

  it("logs a notifier that throws and leaves the memo parked", async () => {
    const { store, notifier, binding, publish } = setup();
    notifier.needsRoute = async () => {
      throw new Error("boom");
    };
    const id = parkMemo(store, { reason: "decide refused" });
    const { lines } = await captureLogs(async () => {
      publish(id);
      await binding.idle();
    });
    expect(lines.map((l) => l["event"])).toEqual(["notify.needs_route_failed"]);
    expect(store.getMemo(id)?.state).toBe("needs_route");
  });

  it("idle waits for an alert in flight; stop ends the subscription", async () => {
    const { store, notifier, binding, publish } = setup();
    const gate = deferred();
    notifier.needsRoute = () => gate.promise;
    const id = parkMemo(store, { reason: "decide refused" });
    publish(id);
    const idle = binding.idle();
    expect(await settled(idle)).toBe(false);
    gate.resolve();
    expect(await settled(idle)).toBe(true);

    binding.stop();
    notifier.needsRoute = async (params) => {
      notifier.needsRouteCalls.push(params);
    };
    publish(id);
    await binding.idle();
    expect(notifier.needsRouteCalls).toEqual([]);
  });
});
