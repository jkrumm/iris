import { Database } from "bun:sqlite";
import { createSqliteMemoStore } from "../adapters/sqlite.js";
import { bytesRecording, type AudioStore } from "../ports/audio.js";
import { manualClock } from "../ports/clock.js";
import type { Memo, MemoState } from "./memo.js";
import type { MemoStore } from "./store.js";

export interface FakeAudio extends AudioStore {
  files: Map<string, Uint8Array>;
  combined: Map<string, Uint8Array>;
}

const key = ({ id, index }: { id: string; index: number }) => `${id}/${index}`;

export function fakeAudio(): FakeAudio {
  const files = new Map<string, Uint8Array>();
  const combined = new Map<string, Uint8Array>();
  return {
    files,
    combined,
    async put({ id, index, bytes }) {
      files.set(key({ id, index }), bytes);
    },
    path: (params) => `/fake/${key(params)}.m4a`,
    async removeSegment(params) {
      files.delete(key(params));
    },
    async remove(id) {
      for (const k of Array.from(files.keys())) if (k.startsWith(`${id}/`)) files.delete(k);
      combined.delete(id);
    },
    async readCombined(id) {
      const bytes = combined.get(id);
      return bytes ? bytesRecording(bytes) : null;
    },
    async putCombined({ id, bytes }) {
      combined.set(id, bytes);
    },
  };
}

export function testStore() {
  const clock = manualClock();
  const db = new Database(":memory:");
  return { db, clock, store: createSqliteMemoStore({ db, clock }) };
}

const PATH: MemoState[] = ["received", "transcribed", "routed", "acted", "summarized", "notified"];

/** Creates a memo and walks it through the happy-path states up to `state`. */
export function seedMemo(store: MemoStore, state: MemoState = "receiving", device = "iphone") {
  const id = crypto.randomUUID();
  const { memo } = store.createMemo({
    id,
    mode: "auto",
    device,
    startedAt: "2026-01-01T00:00:00.000Z",
  });
  const target = PATH.indexOf(state);
  if (target >= 0) store.markReceived({ id, segmentCount: 1 });
  for (let i = 1; i <= target; i++) {
    store.transition({ id, from: PATH[i - 1] as MemoState, to: PATH[i] as MemoState });
  }
  return store.getMemo(memo.id) as Memo;
}

/** Walks a fresh memo through `route` into `needs_route`, with the decision row the route step writes. */
export function parkMemo(
  store: MemoStore,
  decision: { source?: "mode" | "prefix" | "decide"; destination?: string | null; reason: string },
  transcript = "kauf bitte Milch",
) {
  const memo = seedMemo(store, "transcribed");
  store.completeStep({
    id: memo.id,
    step: "transcribe",
    from: "transcribed",
    to: "transcribed",
    patch: { transcript },
  });
  store.markStepStarted({ id: memo.id, step: "route" });
  store.completeStep({
    id: memo.id,
    step: "route",
    from: "transcribed",
    to: "needs_route",
    patch: {
      routeDecision: {
        source: decision.source ?? "decide",
        destination: decision.destination ?? null,
        tab: null,
        confidence: null,
        model: null,
        costUsd: null,
        reason: decision.reason,
        outcome: "needs_route",
      },
    },
  });
  return memo.id;
}

export function deferred<T = void>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

/** Runs `fn` with `console.log` captured as parsed JSON log lines (restored afterwards). */
export async function captureLogs<T>(fn: () => Promise<T>) {
  const lines: Record<string, unknown>[] = [];
  // telemetry/log.ts writes through console.log, so that is the sink to intercept.
  /* eslint-disable no-console */
  const original = console.log;
  console.log = (line: unknown) => {
    lines.push(JSON.parse(String(line)) as Record<string, unknown>);
  };
  try {
    return { result: await fn(), lines };
  } finally {
    console.log = original;
  }
  /* eslint-enable no-console */
}
