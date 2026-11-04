import type { MemoMode, Summary, ThreadUpsert } from "../memo/memo.js";

/** What Hermes reported for the turn beyond its reply: the ```iris block (absent or invalid = none) and the tools it used. */
export interface DeliveryMeta {
  /** `normalizeKind` of the block's `kind`; null when there was no valid block or the kind is empty. */
  kind: string | null;
  /** The block's headline and spoken sentence; null when there was no valid block. */
  summary: Summary | null;
  /** Tool names of the turn, deduplicated in first-seen order and capped (`normalizeActions`). */
  actions: string[];
}

export interface Delivery {
  /** Where the message landed: the Hermes session id. */
  ref: string;
  /** The assistant's final answer with the ```iris block stripped; empty when the destination does not answer. */
  replyText: string;
  usage?: unknown;
  costUsd?: number;
  /** The conversation the message landed in. The destination names it; `act` only persists it. */
  thread?: ThreadUpsert;
  meta?: DeliveryMeta;
}

/** The one place a memo goes: Hermes decides what it is and acts. */
export interface Destination {
  /**
   * Hands the transcript to the destination and waits for its reply. `mode` is the owner's pick as the app sent it (the
   * destination turns `chat`, `journal` and `tab` into one hint line). `threadId` delivers into that existing session
   * instead of creating one.
   */
  deliver(params: {
    memoId: string;
    transcript: string;
    mode: MemoMode;
    threadId?: string;
  }): Promise<Delivery>;
}
