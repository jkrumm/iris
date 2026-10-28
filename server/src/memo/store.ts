import type { DestinationName } from "../ports/destination.js";
import type {
  Memo,
  MemoFlags,
  MemoMode,
  MemoPatch,
  MemoState,
  RouteDecisionInput,
  RouteDecisionRecord,
  Step,
  StepRecord,
  Thread,
  ThreadKind,
} from "./memo.js";

/** The most `needs_route` memos the first history page pins. */
export const PINNED_LIMIT = 50;

/** An answer always names a destination, so a routed memo never has `route` NULL. */
export type AnswerDecision = RouteDecisionInput & { destination: DestinationName };

/** The read side of threads; the rows are written by `act` (`MemoPatch.thread`). */
export interface ThreadStore {
  getThread(id: string): Thread | null;
  /**
   * Newest `updated_at` first, ties by id. `nextCursor` is null on the last page; the cursor is the last row's
   * (`updated_at`, id), so it stays valid as threads are added or updated. A malformed cursor is `bad_request`.
   */
  listThreads(params: {
    kind?: ThreadKind | undefined;
    limit: number;
    cursor?: string | null | undefined;
  }): { threads: Thread[]; nextCursor: string | null };
  /** The memos whose `thread_id` is `id`, oldest first. */
  listThreadMemos(id: string): Memo[];
  /** When `act` finished (the assistant's reply landed) for each live memo of the thread that got that far, by memo id. */
  listThreadReplies(id: string): Map<string, string>;
}

/** Synchronous on purpose: the one adapter is bun:sqlite, and every method is a single statement or transaction. */
export interface MemoStore extends ThreadStore {
  /**
   * Idempotent on `id`: an existing memo is returned untouched with `created: false`. `threadId` names the thread the new
   * memo continues (the service has checked it exists); it is ignored for an existing memo.
   */
  createMemo(params: {
    id: string;
    mode: MemoMode;
    device: string;
    startedAt: string;
    threadId?: string | undefined;
  }): {
    memo: Memo;
    created: boolean;
  };
  /**
   * A memo typed instead of spoken: created directly in `transcribed` with `transcript` set, no
   * segments, no ingest or transcribe step. Idempotent on `id` like `createMemo`.
   */
  createTextMemo(params: {
    id: string;
    mode: MemoMode;
    device: string;
    startedAt: string;
    text: string;
    threadId?: string | undefined;
  }): { memo: Memo; created: boolean };
  getMemo(id: string): Memo | null;
  /**
   * History, newest first. `q` searches the transcript and the summary headline (case, umlaut and prefix
   * insensitive, terms ANDed), `route` and `state` filter exactly; all combine. `needs_route` memos never
   * appear in `memos` (so the cursor survives one leaving that state): without a `cursor` they come back in
   * `pinned` instead, every one matching the filters, newest first, at most `PINNED_LIMIT` (`pinnedTruncated` says it was cut). A `done` `needs_route`
   * memo is no open question: it is never pinned and appears in `memos` at its seq position. Soft-deleted memos
   * never appear; archived ones only with `archived`, which then lists nothing else. `favorite` keeps the
   * favorites, `kind` the memos whose thread has that kind. `nextCursor` is null on the last page; cursors stay
   * valid as memos are added.
   */
  listMemos(params: {
    limit: number;
    cursor?: string | null | undefined;
    q?: string | undefined;
    route?: DestinationName | undefined;
    state?: MemoState | undefined;
    favorite?: boolean | undefined;
    archived?: boolean | undefined;
    kind?: ThreadKind | undefined;
  }): {
    memos: Memo[];
    pinned: Memo[];
    /** More than `PINNED_LIMIT` memos match, so `pinned` is cut short; always false with a `cursor`. */
    pinnedTruncated: boolean;
    nextCursor: string | null;
  };

  /** First write wins: false when the index already has a row, which is left untouched. */
  recordSegment(params: { id: string; index: number; bytes: number; sha256: string }): boolean;
  getSegment(params: { id: string; index: number }): { bytes: number; sha256: string } | null;
  listSegmentIndices(id: string): number[];
  deleteSegments(id: string): void;

  /** receiving → received compare-and-set; false when the memo is not `receiving`. */
  markReceived(params: { id: string; segmentCount: number }): boolean;
  /** Compare-and-set on state; false when the memo is not in `from`. */
  transition(params: { id: string; from: MemoState; to: MemoState }): boolean;

  /** Replaces any earlier row for the step, so a re-run starts a clean timeline entry. */
  markStepStarted(params: { id: string; step: Step }): void;
  /**
   * A transient failure the runner will retry: counts the next try on the running step row and records the failure as its
   * `error` (cleared again when a try succeeds). Returns the new attempt number, null when the step is not running.
   */
  markStepRetrying(params: { id: string; step: Step; error: string }): number | null;
  markStepDone(params: {
    id: string;
    step: Step;
    usage?: unknown;
    costUsd?: number | undefined;
  }): void;
  /**
   * Atomic step completion: compare-and-set `from` → `to` first; only when it won, marks the step
   * done, applies `patch` and appends `patch.routeDecision` to the decision log, all in one transaction. False (nothing written) when the memo is no
   * longer in `from`.
   */
  completeStep(params: {
    id: string;
    step: Step;
    from: MemoState;
    to: MemoState;
    usage?: unknown;
    costUsd?: number | undefined;
    patch?: MemoPatch | undefined;
  }): boolean;
  /** Also moves the memo to `failed` and records `failedStep` and `error`. */
  markStepFailed(params: { id: string; step: Step; error: string }): void;
  /** failed → stateBefore(from), clearing error, failedStep, the timeline and the data columns of `from` and later steps; false if not failed. */
  resetForRetry(params: { id: string; from: Step }): boolean;
  listStepRecords(id: string): StepRecord[];
  /** The routing decision log of one memo, oldest first; the last row carries the reason of a `needs_route` park. */
  listRouteDecisions(id: string): RouteDecisionRecord[];

  /**
   * The user's answer to a parked memo, atomically: `needs_route` → `routed`, `memos.route` set to
   * `decision.destination`, `decision` appended to the log. False (nothing written) when the memo is no longer `needs_route`.
   */
  answerRoute(params: { id: string; decision: AnswerDecision }): boolean;
  /** Appends `decision` to the log without touching the memo; false when the memo has not reached `acted` yet (or is `failed`). */
  recordCorrection(params: { id: string; decision: RouteDecisionInput }): boolean;

  /** Sets the given flags of a live memo (`archived` stamps or clears `archived_at`); false when the memo is unknown or soft-deleted. */
  setFlags(params: { id: string } & MemoFlags): boolean;
  /** Soft-deletes at `at`; a memo that is already deleted keeps its `deleted_at`. False when unknown. */
  markDeleted(params: { id: string; at: string }): boolean;
  /** Clears `deleted_at`; false when the memo is unknown or not deleted. */
  restore(id: string): boolean;
  /** Ids of the memos soft-deleted at or before `cutoff` (ISO), oldest deletion first. */
  listPurgeable(cutoff: string): string[];
  /**
   * Removes a soft-deleted memo with its steps, segments, decisions and tokens (the search index follows by trigger).
   * A thread whose `last_memo_id` was the memo points at its newest remaining memo; a thread left with no memos is
   * deleted. False when the memo is unknown or not deleted.
   */
  purge(id: string): boolean;

  /** Memos the runner must resume after a restart: not receiving, notified, failed or needs_route. */
  listNonTerminal(): Memo[];
}
