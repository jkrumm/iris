/** One answered question: the option the decision model picked and its calibrated confidence (0..1). */
export interface Choice {
  choice: string;
  confidence: number;
}

export interface DecideRequest {
  memoId: string;
  /** Everything the model knows: the transcript excerpt and the live herd. */
  state: string;
  /** Destination id → what it is for; at least two. */
  destinations: Record<string, string>;
  /** Tab id → "repo / label"; only when herdr is a choice and there are live tabs. */
  tabs?: Record<string, string> | undefined;
}

export interface Decision {
  /** Null when the model refused (or did not answer) the question. */
  destination: Choice | null;
  tab: Choice | null;
  model: string;
  usage?: unknown;
  costUsd?: number;
}

export interface Decider {
  /** Throws when the decision model cannot be reached or answers off-schema. */
  decide(request: DecideRequest): Promise<Decision>;
}
