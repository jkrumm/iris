import type { MemoEvent, MemoEvents } from "../memo/events.js";
import type { MemoStore } from "../memo/store.js";
import type { DeviceStore } from "../ports/devices.js";
import type { Notifier } from "../ports/notifier.js";
import { log } from "../telemetry/log.js";

/**
 * Forwards memo state changes to `notifier.phase` as Live Activity updates. `receiving` has no
 * activity yet and `notified` is the `end` push's job, so neither sends. Per memo the sends are
 * serialised and coalesced: while one is in flight, further events only mark the memo dirty and
 * the next send reads the memo fresh (latest state wins). Errors are logged, never thrown.
 */
export function bindPhaseUpdates(deps: {
  events: MemoEvents;
  store: MemoStore;
  devices: DeviceStore;
  notifier: Notifier;
}): { stop(): void; idle(): Promise<void> } {
  const { events, store, devices, notifier } = deps;
  const active = new Map<string, { dirty: boolean; done: Promise<void> }>();

  async function drain(id: string, slot: { dirty: boolean }) {
    while (slot.dirty) {
      slot.dirty = false;
      try {
        const memo = store.getMemo(id);
        if (!memo || memo.state === "receiving" || memo.state === "notified") continue;
        await notifier.phase({ memo });
      } catch (err) {
        log("notify.phase_failed", { memo_id: id, error: String(err) });
      }
    }
    active.delete(id);
  }

  const unsubscribe = events.subscribe((event: MemoEvent) => {
    if (event.state === "receiving" || event.state === "notified" || event.flagChange) return;
    const running = active.get(event.id);
    if (running) {
      running.dirty = true;
      return;
    }
    if (!devices.getActivityToken(event.id)) return;
    const slot = { dirty: true, done: Promise.resolve() };
    active.set(event.id, slot);
    slot.done = drain(event.id, slot);
  });

  return {
    stop: unsubscribe,
    async idle() {
      while (active.size > 0) await Promise.all(Array.from(active.values(), (s) => s.done));
    },
  };
}
