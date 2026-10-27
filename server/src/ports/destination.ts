export interface Delivery {
  /** Where the message landed, e.g. the Hermes session id. */
  ref: string;
  /** The assistant's final answer; empty when the destination does not answer. */
  replyText: string;
  usage?: unknown;
  costUsd?: number;
}

export interface Destination {
  /**
   * Hands the transcript to the destination and waits for its reply. `tab` is the resolved herdr tab id
   * and only set for `herdr`. Throws `TabGoneError` when that tab no longer exists. `chat` (Hermes only) opens or continues a
   * side-effect-free conversation instead of a task; `threadId` continues that existing Hermes session, else a new one named after the memo.
   */
  deliver(params: {
    memoId: string;
    transcript: string;
    tab?: string;
    chat?: boolean;
    threadId?: string;
  }): Promise<Delivery>;
}

/** The tab a memo was routed to has been closed since: the memo needs a new route, retrying cannot help. */
export class TabGoneError extends Error {
  constructor(readonly tab: string) {
    super(`tab ${tab} is gone`);
    this.name = "TabGoneError";
  }
}

export const DESTINATION_NAMES = ["hermes", "journal", "herdr"] as const;
export type DestinationName = (typeof DESTINATION_NAMES)[number];

export const isDestinationName = (value: string): value is DestinationName =>
  (DESTINATION_NAMES as readonly string[]).includes(value);

/** The registered act adapters; only these are routing choices. */
export type Destinations = Partial<Record<DestinationName, Destination>>;

/** The names with an adapter behind them; only these are routing choices. */
export const registeredDestinations = (destinations: Destinations): DestinationName[] =>
  DESTINATION_NAMES.filter((name) => destinations[name] !== undefined);

/** With a single registered destination there is nothing to decide, and the decider is not needed. */
export const hasChoice = (registered: readonly DestinationName[]): boolean =>
  registered.length >= 2;
