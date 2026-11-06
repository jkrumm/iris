/**
 * The software factory's read API (`/v1` on loopback), as Iris needs it. Vendor shapes stop at the adapter: unknown enum
 * values arrive as `other`, `repo` paths (local to the mini) are dropped, and display text is `short`/`summary` as the factory wrote it.
 */

export const ASK_KINDS = ["blocker", "question", "human", "note", "permission", "other"] as const;
export type AskKind = (typeof ASK_KINDS)[number];

export const ASK_SOURCES = [
  "hc",
  "wait",
  "factory",
  "decision",
  "queue",
  "reply",
  "other",
] as const;
export type AskSource = (typeof ASK_SOURCES)[number];

export const HEALTH_KINDS = [
  "park",
  "silent",
  "over_budget",
  "regressions",
  "machine",
  "other",
] as const;
export type HealthKind = (typeof HEALTH_KINDS)[number];

export interface FactoryAsk {
  /** Opaque, e.g. `decision:113:1:ask:<uuid>`; never display text. */
  id: string;
  kind: AskKind;
  source: AskSource;
  issue: number | null;
  /** The card title. */
  short: string;
  summary: string;
  at: string;
  stale: boolean;
}

export interface FactoryHealth {
  id: string;
  kind: HealthKind;
  short: string;
  summary: string;
  since: string;
}

export interface FactoryOverview {
  asks: FactoryAsk[];
  health: FactoryHealth[];
  builtAt: string;
}

export interface FactoryAnswerAck {
  issue: number;
  state: string;
  /** The same call id again: the factory recorded nothing new. */
  duplicate: boolean;
}

/** A hint from the change stream; the resources are the truth, a change only says where to look. */
export interface FactoryChange {
  event: "hello" | "issue" | "session" | "fleet" | "other";
  /** The frame's `id:`; resume the next stream with the last one. */
  cursor: string | null;
}

export type FactoryErrorCode =
  | "unavailable"
  | "not_found"
  | "conflict"
  | "bad_request"
  | "cursor_gone";

export class FactoryError extends Error {
  constructor(
    readonly code: FactoryErrorCode,
    message: string,
    options?: { cause?: unknown },
  ) {
    super(message, options);
    this.name = "FactoryError";
  }
}

export interface FactoryReader {
  /** Asks (the factory-owned ones, never the human queue) and health lines. */
  overview(): Promise<FactoryOverview>;
  asks(): Promise<FactoryAsk[]>;
  /** The options of the Issue's open question; empty when it has none. */
  issueQuestion(issue: number): Promise<string[]>;
  /** Answers the Issue's open question. `callId` makes a retry one event. Throws `FactoryError` (`not_found`, `conflict`: no open question). */
  answer(params: { issue: number; callId: string; text: string }): Promise<FactoryAnswerAck>;
  /** The change stream from `since` (absent = now) until `signal` aborts or the stream drops. `cursor_gone` = read the resources again. */
  follow(since: string | undefined, signal: AbortSignal): AsyncIterable<FactoryChange>;
}

/** What happened to one new-ask alert. */
export type FactoryAlertOutcome = "sent" | "no_token" | "rejected" | "retry";

export interface FactoryAlerter {
  /** Never throws. `retry` = a transient failure with no device reached: try again on the next pass. */
  alert(ask: Pick<FactoryAsk, "id" | "issue" | "short" | "summary">): Promise<FactoryAlertOutcome>;
}

/** Which asks were already announced, so a restart or a replayed stream never pushes one twice. */
export interface FactoryPushStore {
  /** True while the first-ever scan has not finished: every open ask then counts as announced (see `claim`'s `silent`). */
  startBaseline(): boolean;
  completeBaseline(): void;
  /**
   * Records the ask as seen. True when it still needs its push: new, or seen before and never announced (a failed try).
   * With `silent`, a new ask is recorded as announced and the answer is false.
   */
  claim(askId: string, opts: { silent: boolean }): boolean;
  markPushed(askId: string): void;
}
