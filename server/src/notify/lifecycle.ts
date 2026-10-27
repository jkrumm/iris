import type { bindNeedsRouteAlerts } from "./needs-route.js";
import type { bindPhaseUpdates } from "./phases.js";

/**
 * What `index.ts` has to wind down for notifications, behind one handle: stop reacting to memo
 * events, wait for the Live Activity pushes and needs-route alerts still in flight, then close the APNs transport (when
 * there is one). Close only after `idle`, so a push in flight is never cut off.
 */
export interface NotifyLifecycle {
  stop(): void;
  idle(): Promise<void>;
  close(): Promise<void>;
}

export function createNotifyLifecycle(deps: {
  phases: ReturnType<typeof bindPhaseUpdates>;
  alerts?: ReturnType<typeof bindNeedsRouteAlerts> | undefined;
  /** The APNs transport's `close`; absent for the log notifier and the fakes. */
  closeTransport?: (() => Promise<void>) | undefined;
}): NotifyLifecycle {
  const { phases, alerts, closeTransport } = deps;
  let closing: Promise<void> | undefined;
  return {
    stop() {
      phases.stop();
      alerts?.stop();
    },
    async idle() {
      await Promise.all([phases.idle(), alerts?.idle()]);
    },
    close() {
      closing ??= closeTransport?.() ?? Promise.resolve();
      return closing;
    },
  };
}
