import type { Memo, MemoMode, MemoState, Step, StepRecord } from "./memo.js";

/** Synchronous on purpose: the one adapter is bun:sqlite, and every method is a single statement or transaction. */
export interface MemoStore {
  /** Idempotent on `id`: an existing memo is returned untouched with `created: false`. */
  createMemo(params: { id: string; mode: MemoMode; device: string; startedAt: string }): {
    memo: Memo;
    created: boolean;
  };
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
  /** Also moves the memo to `failed` and records `failedStep` and `error`. */
  markStepFailed(params: { id: string; step: Step; error: string }): void;
  /** failed → stateBefore(from), clearing error, failedStep and the timeline from `from` on; false if not failed. */
  resetForRetry(params: { id: string; from: Step }): boolean;
  listStepRecords(id: string): StepRecord[];

  /** Memos the runner must resume after a restart: not receiving, notified, failed or needs_route. */
  listNonTerminal(): Memo[];
}
