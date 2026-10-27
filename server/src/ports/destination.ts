export interface Delivery {
  /** Where the message landed, e.g. the Hermes session id. */
  ref: string;
  /** The assistant's final answer; empty when the destination does not answer. */
  replyText: string;
  usage?: unknown;
  costUsd?: number;
}

export interface Destination {
  /** Hands the transcript to the destination and waits for its reply. */
  deliver(params: { memoId: string; transcript: string }): Promise<Delivery>;
}

export const DESTINATION_NAMES = ["hermes", "journal", "herdr"] as const;
export type DestinationName = (typeof DESTINATION_NAMES)[number];

/** The registered act adapters; only these are routing choices. Journal and herdr arrive in Wave 11. */
export type Destinations = Partial<Record<DestinationName, Destination>>;
