import type { Memo, Summary } from "../memo/memo.js";

export interface Notifier {
  /** Tells the user the memo is done. A throw fails the notify step, which is retryable. */
  notify(params: { memo: Memo; summary: Summary }): Promise<void>;
}
