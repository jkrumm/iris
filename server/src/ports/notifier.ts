import type { Memo, Summary } from "../memo/memo.js";

export interface Notifier {
  /** Tells the user the memo is done. A throw fails the notify step, which is retryable. */
  notify(params: { memo: Memo; summary: Summary }): Promise<void>;
  /** Best-effort Live Activity update for a state change. Never throws into the pipeline. */
  phase(params: { memo: Memo }): Promise<void>;
  /**
   * Best-effort alert that the memo parked at `needs_route` and waits for the user's choice. `reason` is
   * the park reason from the decision log, never transcript or reply text. The Live Activity side is
   * `phase`'s job (it already pushes `needsRoute`), so this sends the alert only. Never throws.
   */
  needsRoute(params: { memo: Memo; reason: string | null }): Promise<void>;
}
