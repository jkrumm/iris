import type { bindPhaseUpdates } from "./phases.js";

/**
 * What `index.ts` has to wind down for notifications, behind one handle: stop reacting to memo
 * events, wait for the Live Activity pushes still in flight, then close the APNs transport (when
 * there is one). Close only after `idle`, so a push in flight is never cut off.
 */
export interface NotifyLifecycle {
  stop(): void;
  idle(): Promise<void>;
  close(): Promise<void>;
}

export function createNotifyLifecycle(deps: {
  phases: ReturnType<typeof bindPhaseUpdates>;
  /** The APNs transport's `close`; absent for the log notifier and the fakes. */
  closeTransport?: (() => Promise<void>) | undefined;
}): NotifyLifecycle {
  const { phases, closeTransport } = deps;
  let closing: Promise<void> | undefined;
  return {
    stop: () => phases.stop(),
    idle: () => phases.idle(),
    close() {
      closing ??= closeTransport?.() ?? Promise.resolve();
      return closing;
    },
  };
}
