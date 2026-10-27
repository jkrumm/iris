import { createHash } from "node:crypto";
import type { AudioStore } from "../ports/audio.js";
import type { Clock } from "../ports/clock.js";
import type { DestinationName } from "../ports/destination.js";
import { log } from "../telemetry/log.js";
import { MemoError } from "./errors.js";
import { memoEvent, type MemoEvents, type MemoListener } from "./events.js";
import {
  isResultReady,
  MEMO_MODES,
  type RouteDecisionInput,
  type Memo,
  type MemoMode,
  type MemoState,
  type Step,
  type StepRecord,
} from "./memo.js";
import type { Runner } from "./runner.js";
import type { MemoStore } from "./store.js";

export interface MemoDetail {
  memo: Memo;
  steps: StepRecord[];
  /** Declared by `complete`; until then, the number of segments received so far. */
  segmentCount: number;
}

export interface MemoService {
  /** The per-segment byte cap; the HTTP layer enforces it while streaming the body in. */
  readonly maxSegmentBytes: number;
  createMemo(params: { id: string; mode: MemoMode; device: string; startedAt: string }): {
    memo: Memo;
    created: boolean;
  };
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
  get(id: string): MemoDetail;
  list(params: { limit?: number; cursor?: string | null | undefined }): {
    memos: Memo[];
    nextCursor: string | null;
  };
  /** `ready: false` means the wait timed out or was aborted; `memo` is then the current state. */
  waitForResult(params: {
    id: string;
    waitSeconds: number;
    signal?: AbortSignal;
  }): Promise<{ memo: Memo; ready: boolean }>;
  subscribe(listener: MemoListener): () => void;
}

/** States after `act`, where a route can no longer change the outcome and is only recorded. */
const CORRECTABLE_STATES: readonly MemoState[] = ["acted", "summarized", "notified"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_SEGMENTS = 1_000_000; // matches the six-digit file names of the audio store
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

  const mustGet = (id: string) => {
    const memo = store.getMemo(id);
    if (!memo) throw new MemoError("not_found", `memo ${id} not found`);
    return memo;
  };

  return {
    maxSegmentBytes,

    createMemo({ id, mode, device, startedAt }) {
      if (!UUID.test(id)) throw new MemoError("bad_request", "id must be a UUID");
      if (!MEMO_MODES.includes(mode)) throw new MemoError("bad_request", `unknown mode ${mode}`);
      if (Number.isNaN(Date.parse(startedAt))) {
        throw new MemoError("bad_request", "startedAt must be an ISO timestamp");
      }
      const result = store.createMemo({ id, mode, device, startedAt });
      if (!result.created) {
        if (result.memo.device !== device) {
          throw new MemoError("conflict", `memo ${id} belongs to another device`);
        }
        return result;
      }
      events.publish(memoEvent({ memo: result.memo, step: null, clock }));
      return result;
    },

    async putSegment({ id, index, bytes }) {
      const memo = mustGet(id);
      if (memo.state !== "receiving") {
        throw new MemoError("bad_state", `memo ${id} is ${memo.state}, no longer receiving`);
      }
      assertSegment({ index, bytes, maxBytes: maxSegmentBytes });
      const sha256 = createHash("sha256").update(bytes).digest("hex");
      // Uploads of one (memo, index) run one at a time, so a conflicting upload can never
      // replace the file a stored sha256 describes.
      await serialized(`${id}/${index}`, async () => {
        const existing = store.getSegment({ id, index });
        if (existing) return assertSameSegment({ id, index, stored: existing.sha256, sha256 });
        await audio.put({ id, index, bytes });
        // `complete` may have run while the write was in flight; the check and the insert below
        // are synchronous, so no row can land after the memo left `receiving`.
        if (mustGet(id).state !== "receiving") {
          throw new MemoError("bad_state", `memo ${id} is no longer receiving`);
        }
        store.recordSegment({ id, index, bytes: bytes.byteLength, sha256 });
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
      runner
        .drive(id)
        .catch((err: unknown) => log("memo.drive_failed", { memo_id: id, error: String(err) }));
      return received;
    },

    retry: (params) => runner.retry(params),

    route({ id, destination, tab }) {
      const memo = mustGet(id);
      const isAnswer = memo.state === "needs_route";
      if (!isAnswer && !CORRECTABLE_STATES.includes(memo.state)) {
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
      const decision: RouteDecisionInput = {
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
        runner
          .drive(id)
          .catch((err: unknown) => log("memo.drive_failed", { memo_id: id, error: String(err) }));
      }
      return { memo: mustGet(id), accepted: isAnswer };
    },

    get(id) {
      const memo = mustGet(id);
      return {
        memo,
        steps: store.listStepRecords(id),
        segmentCount: memo.segmentCount ?? store.listSegmentIndices(id).length,
      };
    },

    list({ limit = DEFAULT_LIMIT, cursor }) {
      return store.listMemos({
        limit: Math.min(Math.max(Math.floor(limit), 1), MAX_LIMIT),
        cursor,
      });
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
