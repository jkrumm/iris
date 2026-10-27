import type { MemoEvent, MemoEvents } from "../memo/events.js";
import type { MemoStore } from "../memo/store.js";
import type { Notifier } from "../ports/notifier.js";
import { log } from "../telemetry/log.js";

/**
 * Sends one `MEMO_NEEDS_ROUTE` alert when a memo enters `needs_route`. The Live Activity update for
 * that state is `bindPhaseUpdates`' job, so this binding sends the alert only. A memo that was answered
 * before the push goes out is skipped (the answer already moved it on). Best effort: errors are
 * logged and the memo stays parked. `idle` resolves once every alert in flight has settled.
 */
export function bindNeedsRouteAlerts(deps: {
  events: MemoEvents;
  store: MemoStore;
  notifier: Notifier;
}): { stop(): void; idle(): Promise<void> } {
  const { events, store, notifier } = deps;
  const inflight = new Set<Promise<void>>();

  async function alert(id: string) {
    try {
      const memo = store.getMemo(id);
      if (memo?.state !== "needs_route") return;
      await notifier.needsRoute({ memo, reason: memo.routeReason ?? null });
    } catch (err) {
      log("notify.needs_route_failed", { memo_id: id, error: String(err) });
    }
  }

  const unsubscribe = events.subscribe((event: MemoEvent) => {
    if (event.state !== "needs_route") return;
    const run = alert(event.id).finally(() => inflight.delete(run));
    inflight.add(run);
  });

  return {
    stop: unsubscribe,
    async idle() {
      while (inflight.size > 0) await Promise.all(Array.from(inflight));
    },
  };
}
