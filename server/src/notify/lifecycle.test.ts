import { describe, expect, it } from "bun:test";
import { createSqliteDeviceStore } from "../adapters/sqlite-devices.js";
import { createMemoEvents, memoEvent } from "../memo/events.js";
import type { Memo } from "../memo/memo.js";
import { deferred, seedMemo, testStore } from "../memo/test-support.js";
import { fakeNotifier } from "../ports/fakes.js";
import { createNotifyLifecycle } from "./lifecycle.js";
import { bindPhaseUpdates } from "./phases.js";

function setup(options: { closeTransport?: () => Promise<void> } = {}) {
  const { db, clock, store } = testStore();
  const devices = createSqliteDeviceStore({ db, clock });
  const events = createMemoEvents();
  const memo = seedMemo(store, "received");
  devices.setActivityToken({ memoId: memo.id, token: "aa11" });

  // A notifier whose phase push stays in flight until the test releases it.
  const push = deferred();
  const notifier = { ...fakeNotifier(), phase: () => push.promise };
  const phases = bindPhaseUpdates({ events, store, devices, notifier });
  const lifecycle = createNotifyLifecycle({ phases, ...options });
  const emit = () => {
    store.transition({ id: memo.id, from: "received", to: "transcribed" });
    events.publish(memoEvent({ memo: store.getMemo(memo.id) as Memo, step: "transcribe", clock }));
  };
  return { lifecycle, push, emit };
}

const settled = (promise: Promise<unknown>) =>
  Promise.race([promise.then(() => true), new Promise<false>((r) => setTimeout(r, 20, false))]);

describe("notify lifecycle", () => {
  it("idle waits for an in-flight phase push", async () => {
    const { lifecycle, push, emit } = setup();
    emit();

    const idle = lifecycle.idle();
    expect(await settled(idle)).toBe(false);

    push.resolve();
    expect(await settled(idle)).toBe(true);
  });

  it("stop ends the subscription: later events start no push", async () => {
    const { lifecycle, push, emit } = setup();
    lifecycle.stop();
    emit();
    expect(await settled(lifecycle.idle())).toBe(true);
    push.resolve();
  });

  it("close closes the transport once, and tolerates having none", async () => {
    let closed = 0;
    const { lifecycle } = setup({
      closeTransport: async () => {
        closed++;
      },
    });
    await lifecycle.close();
    await lifecycle.close();
    expect(closed).toBe(1);

    await setup().lifecycle.close();
  });

  it("also waits for, and stops, the needs-route alerts", async () => {
    const gate = deferred();
    let stopped = false;
    const alerts = {
      stop: () => {
        stopped = true;
      },
      idle: () => gate.promise,
    };
    const { phases } = (() => {
      const { db, clock, store } = testStore();
      const devices = createSqliteDeviceStore({ db, clock });
      return {
        phases: bindPhaseUpdates({
          events: createMemoEvents(),
          store,
          devices,
          notifier: fakeNotifier(),
        }),
      };
    })();
    const lifecycle = createNotifyLifecycle({ phases, alerts });
    const idle = lifecycle.idle();
    expect(await settled(idle)).toBe(false);
    gate.resolve();
    expect(await settled(idle)).toBe(true);
    lifecycle.stop();
    expect(stopped).toBe(true);
  });
});
