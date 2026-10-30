import { createHash } from "node:crypto";
import type { AudioStore } from "../ports/audio.js";
import type { Clock } from "../ports/clock.js";
import type { DestinationName } from "../ports/destination.js";
import { log } from "../telemetry/log.js";
import { MemoError } from "./errors.js";
import { memoEvent, type MemoEvents, type MemoListener } from "./events.js";
import {
  continuedThread,
  isCorrectable,
  isDeletable,
  isResultReady,
  isRoutableMode,
  isTyped,
  MEMO_MODES,
  type Memo,
  type MemoFlags,
  type MemoMode,
  type MemoState,
  type Step,
  type StepRecord,
  type Thread,
  type ThreadKind,
  type ThreadMessage,
  purgeAt,
  threadMessages,
} from "./memo.js";
import type { Runner } from "./runner.js";
import type { AnswerDecision, MemoStore } from "./store.js";

export interface MemoDetail {
  memo: Memo;
  steps: StepRecord[];
  /** Declared by `complete`; until then, the number of segments received so far. */
  segmentCount: number;
}

export interface ThreadDetail {
  thread: Thread;
  /** The memos that ran in the thread, oldest first. */
  memos: Memo[];
  /** The conversation built from those memos' transcripts and replies. */
  messages: ThreadMessage[];
}

export interface MemoService {
  /** The per-segment byte cap; the HTTP layer enforces it while streaming the body in. */
  readonly maxSegmentBytes: number;
  createMemo(params: {
    id: string;
    mode: MemoMode;
    device: string;
    startedAt: string;
    /** Continues this thread (404 when unknown): the memo is delivered into its Hermes session. */
    threadId?: string | undefined;
  }): {
    memo: Memo;
    created: boolean;
  };
  /**
   * A memo typed instead of spoken: created in `transcribed` with `transcript = text` and driven from
   * `route`. Idempotent by id: the same body returns the memo, any other body (or device) is a conflict.
   */
  createTextMemo(params: {
    id: string;
    mode: MemoMode;
    device: string;
    startedAt: string;
    text: string;
    threadId?: string | undefined;
  }): { memo: Memo; created: boolean };
  putSegment(params: { id: string; index: number; bytes: Uint8Array }): Promise<void>;
  complete(params: { id: string; segmentCount: number }): Memo;
  retry(params: { id: string; from: Step }): Memo;
  /**
   * The user's answer to routing. `needs_route`: routes the memo, publishes `routed` and drives it on
   * (`accepted: true`; a second answer is `bad_state` because the memo has left `needs_route`). After
   * `act` (acted / summarized / notified): only logs a `correction`, the memo is unchanged. Any other state is `bad_state`.
   */
  route(params: { id: string; destination: DestinationName; tab?: string | undefined }): {
    memo: Memo;
    accepted: boolean;
  };
  /**
   * Sets the given flags (at least one). `bad_state` on a soft-deleted memo. Publishes a flag-change `memo.updated`
   * (`flagChange`: the pipeline did not move, so no `memo.done`, alert or Live Activity push goes with it).
   */
  setFlags(params: { id: string } & MemoFlags): Memo;
  /**
   * Soft delete: the memo stays readable and restorable until `purgeAt`, then the purger removes it. Only settled
   * memos (`notified`, `failed`, `needs_route`) and a memo still `receiving` (a cancelled take; its segments and
   * `complete` are refused with `bad_state` from then on) can be deleted, else `bad_state`. Repeatable: a second call returns
   * the memo with its first `deletedAt` and publishes nothing.
   */
  delete(id: string): Memo;
  /** Undo of `delete`: `bad_state` when the memo is not deleted, `not_found` once its undo window is over (purged or about to be). */
  restore(id: string): Memo;
  get(id: string): MemoDetail;
  list(params: {
    limit?: number;
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
    pinnedTruncated: boolean;
    nextCursor: string | null;
  };
  /** Newest `updated_at` first; the same limit and cursor rules as `list`. */
  listThreads(params: {
    kind?: ThreadKind | undefined;
    limit?: number;
    cursor?: string | null | undefined;
  }): { threads: Thread[]; nextCursor: string | null };
  /** The thread, its memos and the conversation they make up (Iris's own record, no downstream read); 404 when unknown. */
  getThread(id: string): ThreadDetail;
  /** `ready: false` means the wait timed out or was aborted; `memo` is then the current state. */
  waitForResult(params: {
    id: string;
    waitSeconds: number;
    signal?: AbortSignal;
  }): Promise<{ memo: Memo; ready: boolean }>;
  subscribe(listener: MemoListener): () => void;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_SEGMENTS = 1_000_000; // matches the six-digit file names of the audio store
/** The limit on a typed memo's trimmed text, in Unicode code points. */
export const MAX_TEXT_CHARS = 20_000;
const DEFAULT_LIMIT = 20;
const MAX_LIMIT = 100;

function assertSegment(params: { index: number; bytes: Uint8Array; maxBytes: number }) {
  const { index, bytes, maxBytes } = params;
  if (!Number.isInteger(index) || index < 0 || index >= MAX_SEGMENTS) {
    throw new MemoError("bad_request", "segment index out of range");
  }
  if (bytes.byteLength === 0) throw new MemoError("bad_request", "empty segment");
  if (bytes.byteLength > maxBytes) {
    throw new MemoError("too_large", `segment exceeds ${maxBytes} bytes`, { maxBytes });
  }
}

function assertSameSegment(params: {
  id: string;
  index: number;
  stored: string | undefined;
  sha256: string;
}) {
  const { id, index, stored, sha256 } = params;
  if (stored === sha256) return;
  throw new MemoError("conflict", `segment ${index} of ${id} already holds other bytes`);
}

/** A soft-deleted memo takes no change: restore it first. */
function assertLive(memo: Memo) {
  if (memo.deletedAt !== null) throw new MemoError("bad_state", `memo ${memo.id} is deleted`);
}

/** A replay must name the thread the memo was created in (or none, for a memo that continues none). */
function assertSameThread(memo: Memo, threadId: string | undefined) {
  if (continuedThread(memo) === (threadId ?? null)) return;
  throw new MemoError("conflict", `memo ${memo.id} already exists with another thread`);
}

export function createMemoService(deps: {
  store: MemoStore;
  runner: Runner;
  events: MemoEvents;
  audio: AudioStore;
  clock: Clock;
  maxSegmentBytes: number;
  /** The destinations with an act adapter; an answer may only pick one of these. Default: none. */
  destinations?: readonly DestinationName[] | undefined;
}): MemoService {
  const { store, runner, events, audio, clock, maxSegmentBytes, destinations = [] } = deps;

  const writing = new Map<string, Promise<unknown>>();
  const serialized = async (key: string, work: () => Promise<void>) => {
    const run = (writing.get(key) ?? Promise.resolve()).catch(() => undefined).then(work);
    writing.set(key, run);
    try {
      await run;
    } finally {
      if (writing.get(key) === run) writing.delete(key);
    }
  };

  /**
   * A thread to continue must exist, and Hermes (the only destination that keeps threads) must be registered: a turn
   * accepted now could only fail at route. A replay of an existing memo is judged by its stored thread instead
   * (`assertSameThread`).
   */
  const assertCanContinue = (params: { id: string; threadId: string | undefined }) => {
    const { id, threadId } = params;
    if (threadId === undefined || store.getMemo(id)) return;
    if (!store.getThread(threadId)) {
      throw new MemoError("not_found", `thread ${threadId} not found`);
    }
    if (!destinations.includes("hermes")) {
      throw new MemoError(
        "destination_unavailable",
        "hermes is not available, so a thread cannot be continued",
      );
    }
  };

  /** A thread continues in Hermes, which a transcribe-only memo never reaches. */
  const assertNoThreadInTranscribe = (params: { mode: MemoMode; threadId: string | undefined }) => {
    if (!isRoutableMode(params.mode) && params.threadId !== undefined) {
      throw new MemoError("bad_request", "mode transcribe cannot continue a thread");
    }
  };

  const publishFlagChange = (memo: Memo) =>
    events.publish(memoEvent({ memo, step: null, clock, flagChange: true }));

  const drive = (id: string) =>
    runner
      .drive(id)
      .catch((err: unknown) => log("memo.drive_failed", { memo_id: id, error: String(err) }));

  const mustGet = (id: string) => {
    const memo = store.getMemo(id);
    if (!memo) throw new MemoError("not_found", `memo ${id} not found`);
    return memo;
  };

  return {
    maxSegmentBytes,

    createMemo({ id, mode, device, startedAt, threadId }) {
      if (!UUID.test(id)) throw new MemoError("bad_request", "id must be a UUID");
      if (!MEMO_MODES.includes(mode)) throw new MemoError("bad_request", `unknown mode ${mode}`);
      if (Number.isNaN(Date.parse(startedAt))) {
        throw new MemoError("bad_request", "startedAt must be an ISO timestamp");
      }
      assertNoThreadInTranscribe({ mode, threadId });
      assertCanContinue({ id, threadId });
      const result = store.createMemo({ id, mode, device, startedAt, threadId });
      if (!result.created) {
        if (result.memo.device !== device) {
          throw new MemoError("conflict", `memo ${id} belongs to another device`);
        }
        assertSameThread(result.memo, threadId);
        return result;
      }
      events.publish(memoEvent({ memo: result.memo, step: null, clock }));
      return result;
    },

    createTextMemo({ id, mode, device, startedAt, text, threadId }) {
      if (!UUID.test(id)) throw new MemoError("bad_request", "id must be a UUID");
      if (!MEMO_MODES.includes(mode)) throw new MemoError("bad_request", `unknown mode ${mode}`);
      if (Number.isNaN(Date.parse(startedAt))) {
        throw new MemoError("bad_request", "startedAt must be an ISO timestamp");
      }
      const trimmed = text.trim();
      if (trimmed === "") throw new MemoError("bad_request", "text must not be empty");
      if ([...trimmed].length > MAX_TEXT_CHARS) {
        throw new MemoError("bad_request", `text exceeds ${MAX_TEXT_CHARS} characters`);
      }
      assertNoThreadInTranscribe({ mode, threadId });
      assertCanContinue({ id, threadId });
      const result = store.createTextMemo({ id, mode, device, startedAt, text: trimmed, threadId });
      if (!result.created) {
        const { memo } = result;
        if (memo.device !== device) {
          throw new MemoError("conflict", `memo ${id} belongs to another device`);
        }
        const same =
          isTyped(memo) &&
          memo.mode === mode &&
          memo.startedAt === startedAt &&
          memo.transcript === trimmed &&
          continuedThread(memo) === (threadId ?? null);
        if (!same) throw new MemoError("conflict", `memo ${id} already exists with another body`);
        return result;
      }
      events.publish(memoEvent({ memo: result.memo, step: null, clock }));
      void drive(id);
      return result;
    },

    async putSegment({ id, index, bytes }) {
      const memo = mustGet(id);
      if (memo.state !== "receiving") {
        throw new MemoError("bad_state", `memo ${id} is ${memo.state}, no longer receiving`);
      }
      assertLive(memo);
      assertSegment({ index, bytes, maxBytes: maxSegmentBytes });
      const sha256 = createHash("sha256").update(bytes).digest("hex");
      // Uploads of one (memo, index) run one at a time, so a conflicting upload can never
      // replace the file a stored sha256 describes.
      await serialized(`${id}/${index}`, async () => {
        const existing = store.getSegment({ id, index });
        if (existing) return assertSameSegment({ id, index, stored: existing.sha256, sha256 });
        await audio.put({ id, index, bytes });
        // `complete` or `delete` may have run while the write was in flight; the check and the insert below
        // are synchronous, so no row can land after the memo left `receiving` or was deleted.
        try {
          const current = mustGet(id);
          if (current.state !== "receiving") {
            throw new MemoError("bad_state", `memo ${id} is no longer receiving`);
          }
          assertLive(current);
          store.recordSegment({ id, index, bytes: bytes.byteLength, sha256 });
        } catch (err) {
          // No row names this file, so nothing the memo (or a restore of it) needs is lost; the purge would only find it later.
          await audio.removeSegment({ id, index }).catch((cleanup: unknown) => {
            log("segment.cleanup_failed", { memo_id: id, index, error: String(cleanup) });
          });
          throw err;
        }
      });
    },

    complete({ id, segmentCount }) {
      if (!Number.isInteger(segmentCount) || segmentCount < 1 || segmentCount > MAX_SEGMENTS) {
        throw new MemoError("bad_request", "segmentCount must be a positive integer");
      }
      const memo = mustGet(id);
      if (memo.state !== "receiving") {
        if (memo.segmentCount === segmentCount) return memo;
        throw new MemoError(
          "conflict",
          `memo ${id} was completed with ${memo.segmentCount} segments`,
        );
      }
      assertLive(memo);
      const have = new Set(store.listSegmentIndices(id));
      const missing = Array.from({ length: segmentCount }, (_, i) => i).filter((i) => !have.has(i));
      if (missing.length > 0) {
        throw new MemoError("missing_segments", `${missing.length} segments missing`, { missing });
      }
      if (!store.markReceived({ id, segmentCount })) {
        throw new MemoError("bad_state", `memo ${id} is no longer receiving`);
      }
      const received = mustGet(id);
      events.publish(memoEvent({ memo: received, step: "ingest", clock }));
      void drive(id);
      return received;
    },

    retry(params) {
      const existing = store.getMemo(params.id);
      if (existing) assertLive(existing);
      // A typed memo has no audio to transcribe again: `transcribe` would clear its only text.
      if (params.from === "transcribe") {
        const memo = store.getMemo(params.id);
        if (memo && isTyped(memo)) {
          throw new MemoError("bad_request", "a typed memo has no recording, retry from route");
        }
      }
      return runner.retry(params);
    },

    route({ id, destination, tab }) {
      const memo = mustGet(id);
      assertLive(memo);
      // Like a typed memo's retry from transcribe: the request names something this memo does not have.
      if (!isRoutableMode(memo.mode)) {
        throw new MemoError("bad_request", "a transcribe memo has no route to answer or correct");
      }
      const isAnswer = memo.state === "needs_route";
      if (!isAnswer && !isCorrectable(memo.state)) {
        throw new MemoError(
          "bad_state",
          `memo ${id} is ${memo.state}, only parked or acted memos take a route`,
        );
      }
      if (isAnswer && !destinations.includes(destination)) {
        throw new MemoError("bad_request", `${destination} not available`);
      }
      if ((destination === "herdr") !== (tab !== undefined)) {
        throw new MemoError("bad_request", "tab is required for herdr and only for herdr");
      }
      const decision: AnswerDecision = {
        source: isAnswer ? "answer" : "correction",
        destination,
        tab: tab ?? null,
        confidence: null,
        model: null,
        costUsd: null,
        reason: null,
        outcome: "routed",
      };
      const written = isAnswer
        ? store.answerRoute({ id, decision })
        : store.recordCorrection({ id, decision });
      if (!written) throw new MemoError("bad_state", `memo ${id} changed state, route not applied`);
      log("route.decided", {
        memo: id,
        source: decision.source,
        destination,
        confidence: null,
        outcome: "routed",
        reason: null,
        ...(!isAnswer && { corrected: true }),
      });
      if (isAnswer) {
        events.publish(memoEvent({ memo: mustGet(id), step: "route", clock }));
        void drive(id);
      }
      return { memo: mustGet(id), accepted: isAnswer };
    },

    setFlags({ id, done, favorite, archived }) {
      if (done === undefined && favorite === undefined && archived === undefined) {
        throw new MemoError("bad_request", "set at least one of done, favorite, archived");
      }
      assertLive(mustGet(id));
      if (!store.setFlags({ id, done, favorite, archived })) {
        throw new MemoError("bad_state", `memo ${id} is deleted`);
      }
      const memo = mustGet(id);
      publishFlagChange(memo);
      return memo;
    },

    delete(id) {
      const memo = mustGet(id);
      if (memo.deletedAt !== null) return memo;
      if (!isDeletable(memo.state)) {
        throw new MemoError(
          "bad_state",
          `memo ${id} is ${memo.state}, only settled memos can be deleted`,
        );
      }
      store.markDeleted({ id, at: clock.now().toISOString() });
      const deleted = mustGet(id);
      publishFlagChange(deleted);
      return deleted;
    },

    restore(id) {
      const memo = mustGet(id);
      const until = purgeAt(memo);
      if (until === null) throw new MemoError("bad_state", `memo ${id} is not deleted`);
      // Past its window the memo is the sweeper's: the files may be going already.
      if (until <= clock.now().toISOString()) {
        throw new MemoError("not_found", `memo ${id} was purged`);
      }
      if (!store.restore(id)) throw new MemoError("bad_state", `memo ${id} is not deleted`);
      const restored = mustGet(id);
      publishFlagChange(restored);
      return restored;
    },

    get(id) {
      const memo = mustGet(id);
      return {
        memo,
        steps: store.listStepRecords(id),
        segmentCount: memo.segmentCount ?? store.listSegmentIndices(id).length,
      };
    },

    list({ limit = DEFAULT_LIMIT, cursor, q, route, state, favorite, archived, kind }) {
      return store.listMemos({
        limit: Math.min(Math.max(Math.floor(limit), 1), MAX_LIMIT),
        cursor,
        q,
        route,
        state,
        favorite,
        archived,
        kind,
      });
    },

    listThreads({ kind, limit = DEFAULT_LIMIT, cursor }) {
      return store.listThreads({
        kind,
        limit: Math.min(Math.max(Math.floor(limit), 1), MAX_LIMIT),
        cursor,
      });
    },

    getThread(id) {
      const thread = store.getThread(id);
      if (!thread) throw new MemoError("not_found", `thread ${id} not found`);
      const memos = store.listThreadMemos(id);
      const replies = store.listThreadReplies(id);
      const messages = threadMessages(
        memos.map((memo) => ({ memo, repliedAt: replies.get(memo.id) ?? null })),
      );
      return { thread, memos, messages };
    },

    waitForResult({ id, waitSeconds, signal }) {
      const memo = mustGet(id);
      if (isResultReady(memo.state)) return Promise.resolve({ memo, ready: true });
      if (waitSeconds <= 0 || signal?.aborted) return Promise.resolve({ memo, ready: false });

      return new Promise((resolve) => {
        const finish = (ready: boolean) => {
          unsubscribe();
          clearTimeout(timer);
          signal?.removeEventListener("abort", onAbort);
          resolve({ memo: store.getMemo(id) ?? memo, ready });
        };
        const onAbort = () => finish(false);
        const unsubscribe = events.subscribe((event) => {
          if (event.id === id && isResultReady(event.state)) finish(true);
        });
        const timer = setTimeout(() => finish(false), waitSeconds * 1000);
        signal?.addEventListener("abort", onAbort, { once: true });
      });
    },

    subscribe: (listener) => events.subscribe(listener),
  };
}
