import type {
  Memo,
  MemoFlags,
  MemoMode,
  MemoPatch,
  MemoState,
  ReplyAsset,
  Step,
  StepRecord,
  Thread,
} from "./memo.js";

/** The read side of threads; the rows are written by `act` (`MemoPatch.thread`). */
export interface ThreadStore {
  getThread(id: string): Thread | null;
  /**
   * Newest `updated_at` first, ties by id. `nextCursor` is null on the last page; the cursor is the last row's
   * (`updated_at`, id), so it stays valid as threads are added or updated. A malformed cursor is `bad_request`.
   */
  listThreads(params: { limit: number; cursor?: string | null | undefined }): {
    threads: Thread[];
    nextCursor: string | null;
  };
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
   * insensitive, terms ANDed), `kind` (the memo's kind, exact; the caller normalises it) and `state` filter exactly; all
   * combine. Soft-deleted memos never appear; archived ones only with `archived`, which then lists nothing else. `favorite`
   * keeps the favorites, `thread` the memos of a conversation (a thread with at least two live memos: one that was continued; a memo alone in its session is none). `nextCursor` is null on the last page; cursors stay
   * valid as memos are added.
   */
  listMemos(params: {
    limit: number;
    cursor?: string | null | undefined;
    q?: string | undefined;
    kind?: string | undefined;
    state?: MemoState | undefined;
    favorite?: boolean | undefined;
    archived?: boolean | undefined;
    thread?: boolean | undefined;
  }): {
    memos: Memo[];
    nextCursor: string | null;
  };

  /** First write wins: false when the index already has a row, which is left untouched. */
  recordSegment(params: { id: string; index: number; bytes: number; sha256: string }): boolean;
  getSegment(params: { id: string; index: number }): { bytes: number; sha256: string } | null;
  listSegmentIndices(id: string): number[];
  deleteSegments(id: string): void;

  /** receiving → received compare-and-set; false when the memo is not `receiving` or is soft-deleted. */
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
   * done and applies `patch`, all in one transaction. False (nothing written) when the memo is no
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
  /**
   * An optional step failed for good: records the failure on its step row (error and attempts stay) and moves the memo
   * on to the state the step would have reached, compare-and-set from `from`, without marking the memo failed. False
   * (nothing written, the step row stays as it was) when the memo left `from`. Throws for a step that is not optional.
   */
  skipStep(params: { id: string; step: Step; from: MemoState; error: string }): boolean;
  /**
   * failed → stateBefore(from), clearing error, failedStep, the timeline and the data columns of `from` and later steps (steps an
   * old memo had and the pipeline no longer has included); false if not failed. Also resets a `notified` memo when `from` is an
   * optional step whose row is `failed` (the memo ended without its result).
   */
  resetForRetry(params: { id: string; from: Step }): boolean;
  listStepRecords(id: string): StepRecord[];
  /** Sets the given flags of a live memo (`archived` stamps or clears `archived_at`); false when the memo is unknown or soft-deleted. */
  setFlags(params: { id: string } & MemoFlags): boolean;
  /** Soft-deletes at `at`; a memo that is already deleted keeps its `deleted_at`. False when unknown. */
  markDeleted(params: { id: string; at: string }): boolean;
  /** Clears `deleted_at`; false when the memo is unknown or not deleted. */
  restore(id: string): boolean;
  /** Ids of the memos soft-deleted at or before `cutoff` (ISO), oldest deletion first. */
  listPurgeable(cutoff: string): string[];
  /**
   * Removes a soft-deleted memo with its steps, segments, old routing decisions, reply assets and tokens (the search index follows by trigger).
   * A thread whose `last_memo_id` was the memo points at its newest remaining memo; a thread left with no memos is
   * deleted. False when the memo is unknown or not deleted.
   */
  purge(id: string): boolean;

  /**
   * Stages the assets rendered for a reply that `completeStep` has not committed yet (the `act` handler renders before its
   * patch lands). Nothing is visible, no row is written, until `completeStep` commits a patch whose `replyText` is
   * `staged.replyText`: that transaction replaces the memo's rows with the staged ones (and sets or clears the failed
   * marker) and `onSettled("committed")` follows. A patch that loses its compare-and-set changes nothing, so the rows
   * of an earlier committed reply stay, and `onSettled("discarded")` follows (the new files are the caller's to remove).
   * A winning patch with any other reply text drops the rows (they describe a reply that is gone). Only the latest
   * staging of a memo is tracked, in memory: a newer one settles the older as discarded. `resetForRetry` from `act`
   * discards it too, `purge` forgets it. A restart re-runs the step. False when the memo is unknown (nothing staged).
   */
  stageReplyAssets(id: string, staged: StagedReplyAssets): boolean;
  /**
   * Stores assets for a reply that is already committed (the backfill): only when the memo is live, its `reply_text` is
   * still `replyText` and it has no assets yet. False otherwise; the caller removes its files.
   */
  attachReplyAssets(params: {
    id: string;
    replyText: string;
    assets: readonly ReplyAsset[];
  }): boolean;
  /**
   * Live memos whose `reply_text` mentions mermaid, that have no reply asset rows and are not marked failed, newest first
   * (`seq` below `beforeSeq`). The caller decides whether a reply really contains a fence.
   */
  listReplyAssetCandidates(params: {
    beforeSeq?: number | undefined;
    limit: number;
  }): { id: string; seq: number; replyText: string }[];
  /**
   * Marks the memo's committed reply as one whose diagrams all failed to render, so `listReplyAssetCandidates` skips it.
   * Only while `reply_text` is still `replyText`; a changed reply (a winning `completeStep` with a reply, `resetForRetry`
   * from `act`) clears it. False when the memo is unknown or its reply changed.
   */
  markReplyAssetsFailed(params: { id: string; replyText: string }): boolean;
  /** One asset of the memo, whatever its state (the media route checks deletion itself); null when unknown. */
  getReplyAsset(id: string, assetId: string): ReplyAsset | null;

  /** Memos the runner must resume after a restart: not receiving, notified, failed or (an old row) needs_route. */
  listNonTerminal(): Memo[];
}

/** Reply assets rendered before their reply is committed; see `MemoStore.stageReplyAssets`. */
export interface StagedReplyAssets {
  replyText: string;
  assets: readonly ReplyAsset[];
  /** The reply has Mermaid fences and not one rendered: stored as the failed marker with the commit. */
  failed: boolean;
  /** Called once, after the transaction, when the reply is settled. Must not throw. */
  onSettled: (outcome: "committed" | "discarded") => void;
}
