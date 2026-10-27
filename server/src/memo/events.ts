import { log } from "../telemetry/log.js";
import type { Clock } from "../ports/clock.js";
import type { Memo, MemoState, Step } from "./memo.js";

export interface MemoEvent {
  id: string;
  state: MemoState;
  /** The step that just finished or failed; null for creation and retry resets. */
  step: Step | null;
  failedStep: Step | null;
  error: string | null;
  /** ISO timestamp. */
  at: string;
}

export type MemoListener = (event: MemoEvent) => void;

export interface MemoEvents {
  publish(event: MemoEvent): void;
  subscribe(listener: MemoListener): () => void;
}

export function memoEvent(params: { memo: Memo; step: Step | null; clock: Clock }): MemoEvent {
  const { memo, step, clock } = params;
  return {
    id: memo.id,
    state: memo.state,
    step,
    failedStep: memo.failedStep,
    error: memo.error,
    at: clock.now().toISOString(),
  };
}

/** In-process pub/sub. A throwing listener is logged and never reaches the publisher or its peers. */
export function createMemoEvents(): MemoEvents {
  const listeners = new Set<MemoListener>();
  return {
    publish(event) {
      for (const listener of Array.from(listeners)) {
        try {
          listener(event);
        } catch (err) {
          log("events.listener_error", { memo_id: event.id, error: String(err) });
        }
      }
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  };
}
