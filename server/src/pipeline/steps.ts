import type { HandlerStep, Memo } from "../memo/memo.js";
import type { StepHandler } from "../memo/runner.js";
import type { MemoStore } from "../memo/store.js";
import type { AudioStore } from "../ports/audio.js";
import type { Destination } from "../ports/destination.js";
import type { Notifier } from "../ports/notifier.js";
import type { Summarizer } from "../ports/summarizer.js";
import type { Transcriber } from "../ports/transcriber.js";
import { getActiveSpan } from "../telemetry/otel.js";

// Each step is a pure function of (memo, ports): it reads what earlier steps stored on the memo,
// returns its own result as a patch and never writes the store itself, so it is safe to re-run.

/** This chain always routes to Hermes; the `decide` routing is Phase 2. */
const ROUTE = "hermes";

function required<T>(value: T | null, what: string, step: HandlerStep): T {
  if (value === null) throw new Error(`${step}: memo has no ${what}`);
  return value;
}

export function createStepHandlers(deps: {
  store: MemoStore;
  audio: AudioStore;
  transcriber?: Transcriber | undefined;
  destination?: Destination | undefined;
  summarizer?: Summarizer | undefined;
  notifier: Notifier;
}): Partial<Record<HandlerStep, StepHandler>> {
  const { store, audio, transcriber, destination, summarizer, notifier } = deps;
  const handlers: Partial<Record<HandlerStep, StepHandler>> = {};

  if (transcriber) {
    handlers.transcribe = async ({ memo }) => {
      const segmentPaths = store
        .listSegmentIndices(memo.id)
        .toSorted((a, b) => a - b)
        .map((index) => audio.path({ id: memo.id, index }));
      const result = await transcriber.transcribe({ memoId: memo.id, segmentPaths });
      if (result.text.trim() === "") throw new Error("empty transcript");
      getActiveSpan().setAttributes({
        audio_seconds: result.audioSeconds,
        transcript_chars: result.text.length,
        cost_usd: result.costUsd,
      });
      return {
        patch: { transcript: result.text, audioSeconds: result.audioSeconds },
        usage: { audioSeconds: result.audioSeconds },
        ...(result.costUsd !== undefined && { costUsd: result.costUsd }),
      };
    };
  }

  handlers.route = async () => {
    getActiveSpan().setAttributes({ route: ROUTE });
    return { patch: { route: ROUTE } };
  };

  if (destination) {
    handlers.act = async ({ memo }) => {
      const transcript = required(memo.transcript, "transcript", "act");
      const delivery = await destination.deliver({ memoId: memo.id, transcript });
      getActiveSpan().setAttributes({
        reply_chars: delivery.replyText.length,
        cost_usd: delivery.costUsd,
      });
      return {
        patch: { destinationRef: delivery.ref, replyText: delivery.replyText },
        usage: delivery.usage,
        ...(delivery.costUsd !== undefined && { costUsd: delivery.costUsd }),
      };
    };
  }

  if (summarizer) {
    handlers.summarize = async ({ memo }) => {
      const result = await summarizer.summarize({
        memoId: memo.id,
        route: required(memo.route, "route", "summarize"),
        transcript: required(memo.transcript, "transcript", "summarize"),
        replyText: memo.replyText,
      });
      getActiveSpan().setAttributes({
        summary_chars: result.summary.headline.length + result.summary.detail.length,
        cost_usd: result.costUsd,
      });
      return {
        patch: { summary: result.summary },
        usage: result.usage,
        ...(result.costUsd !== undefined && { costUsd: result.costUsd }),
      };
    };
  }

  handlers.notify = async ({ memo }: { memo: Memo }) => {
    const summary = required(memo.summary, "summary", "notify");
    await notifier.notify({ memo, summary });
    return {};
  };

  return handlers;
}
