import type { DestinationName } from "../ports/destination.js";
import type {
  Memo,
  MemoMode,
  MemoPatch,
  MemoState,
  RouteDecisionInput,
  RouteDecisionRecord,
  Step,
  StepRecord,
} from "./memo.js";

/** An answer always names a destination, so a routed memo never has `route` NULL. */
export type AnswerDecision = RouteDecisionInput & { destination: DestinationName };

/** Synchronous on purpose: the one adapter is bun:sqlite, and every method is a single statement or transaction. */
export interface MemoStore {
  /** Idempotent on `id`: an existing memo is returned untouched with `created: false`. */
  createMemo(params: { id: string; mode: MemoMode; device: string; startedAt: string }): {
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
  }): { memo: Memo; created: boolean };
  getMemo(id: string): Memo | null;
  /** Newest first. `nextCursor` is null on the last page; cursors stay valid as memos are added. */
  listMemos(params: { limit: number; cursor?: string | null | undefined }): {
    memos: Memo[];
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

  /** Memos the runner must resume after a restart: not receiving, notified, failed or needs_route. */
  listNonTerminal(): Memo[];
}
