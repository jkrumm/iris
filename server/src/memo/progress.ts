import { log } from "../telemetry/log.js";
import type { DeliveryProgress } from "../ports/destination.js";

/**
 * What a running `act` shows clients before its reply is stored. A bus of its own, never `MemoEvents`: those drive the
 * Live Activity pushes (`notify/phases.ts`), which must not fire per delta.
 */
export type ProgressEvent =
  | { type: "delta"; id: string; attempt: number; seq: number; text: string }
  | { type: "activity"; id: string; attempt: number; tool: string };

export interface PartialReply {
  attempt: number;
  seq: number;
  text: string;
}

export interface ReplyProgress {
  subscribe(listener: (e: ProgressEvent) => void): () => void;
  /** Text streamed so far for a memo whose act is running; null when none (no turn, or nothing visible yet). */
  partial(id: string): PartialReply | null;
  /** Starts one act attempt for a memo; returns its handle. */
  begin(id: string): ReplyTurn;
}

export interface ReplyTurn {
  onProgress(p: DeliveryProgress): void;
  /** The delivery succeeded: emit what of `replyText` was not yet sent, as one last delta. Synchronous, no throttle. */
  finish(replyText: string): void;
  /** Act ended (success or failure): cancel any timer, drop the partial. Idempotent. */
  end(): void;
}

const DEFAULT_INTERVAL_MS = 150;
const FENCE = "```iris";

/**
 * The part of the raw delta text a client may show: leading whitespace dropped, cut at the ```iris fence (never shown),
 * with a trailing fragment of the fence and trailing whitespace held back (the stored reply is `trimEnd`ed before the
 * fence). Grows monotonically as `raw` grows, and stops growing once the fence is in.
 */
export function visiblePrefix(raw: string): string {
  let text = raw.trimStart();
  const fence = text.indexOf(FENCE);
  if (fence >= 0) return text.slice(0, fence).trimEnd();
  for (let k = Math.min(text.length, FENCE.length - 1); k >= 1; k--) {
    if (text.endsWith(FENCE.slice(0, k))) {
      text = text.slice(0, -k);
      break;
    }
  }
  return text.trimEnd();
}

interface TurnState {
  attempt: number;
  seq: number;
  /** Visible text emitted so far. */
  sent: string;
  ended: boolean;
  end(): void;
}

/** In-process pub/sub. A throwing listener is logged and never reaches the publisher or its peers. */
export function createReplyProgress(opts: { intervalMs?: number } = {}): ReplyProgress {
  const intervalMs = opts.intervalMs ?? DEFAULT_INTERVAL_MS;
  const listeners = new Set<(e: ProgressEvent) => void>();
  const attempts = new Map<string, number>();
  const active = new Map<string, TurnState>();

  const publish = (event: ProgressEvent) => {
    for (const listener of Array.from(listeners)) {
      try {
        listener(event);
      } catch (err) {
        log("progress.listener_error", { memo_id: event.id, error: String(err) });
      }
    }
  };

  return {
    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    partial(id) {
      const turn = active.get(id);
      if (!turn || turn.seq === 0) return null;
      return { attempt: turn.attempt, seq: turn.seq, text: turn.sent };
    },
    begin(id) {
      active.get(id)?.end();
      const attempt = (attempts.get(id) ?? 0) + 1;
      attempts.set(id, attempt);

      let raw = "";
      let lastEmit = Number.NEGATIVE_INFINITY;
      let timer: ReturnType<typeof setTimeout> | undefined;
      const turn: TurnState = {
        attempt,
        seq: 0,
        sent: "",
        ended: false,
        end() {
          if (turn.ended) return;
          turn.ended = true;
          clearTimeout(timer);
          timer = undefined;
          if (active.get(id) === turn) active.delete(id);
        },
      };
      active.set(id, turn);

      const emit = (visible: string) => {
        const text = visible.slice(turn.sent.length);
        turn.sent = visible;
        turn.seq += 1;
        lastEmit = Date.now();
        publish({ type: "delta", id, attempt, seq: turn.seq, text });
      };
      const grew = (visible: string) =>
        visible.length > turn.sent.length && visible.startsWith(turn.sent);
      const flush = () => {
        timer = undefined;
        if (turn.ended) return;
        const visible = visiblePrefix(raw);
        if (grew(visible)) emit(visible);
      };
      const schedule = () => {
        if (timer !== undefined || !grew(visiblePrefix(raw))) return;
        const wait = lastEmit + intervalMs - Date.now();
        if (wait <= 0) return flush();
        timer = setTimeout(flush, wait);
      };

      return {
        onProgress(p) {
          if (turn.ended) return;
          if (p.type === "tool") {
            publish({ type: "activity", id, attempt, tool: p.tool });
            return;
          }
          raw += p.delta;
          schedule();
        },
        finish(replyText) {
          if (turn.ended) return;
          clearTimeout(timer);
          timer = undefined;
          if (replyText.length > turn.sent.length && replyText.startsWith(turn.sent)) {
            emit(replyText);
          }
        },
        end: () => turn.end(),
      };
    },
  };
}
