import type { HandlerStep, Memo } from "../memo/memo.js";
import type { StepHandler } from "../memo/runner.js";
import type { MemoStore } from "../memo/store.js";
import type { AudioStore } from "../ports/audio.js";
import type { Decider } from "../ports/decider.js";
import type { DestinationName, Destinations } from "../ports/destination.js";
import type { Herd } from "../ports/herd.js";
import type { Notifier } from "../ports/notifier.js";
import type { Summarizer } from "../ports/summarizer.js";
import type { Transcriber } from "../ports/transcriber.js";
import { deliveredTranscript, route } from "../routing/index.js";
import { log } from "../telemetry/log.js";
import { getActiveSpan } from "../telemetry/otel.js";

// Each step is a pure function of (memo, ports): it reads what earlier steps stored on the memo,
// returns its own result as a patch and never writes the store itself, so it is safe to re-run.

function required<T>(value: T | null, what: string, step: HandlerStep): T {
  if (value === null) throw new Error(`${step}: memo has no ${what}`);
  return value;
}

export function createStepHandlers(deps: {
  store: MemoStore;
  audio: AudioStore;
  transcriber?: Transcriber | undefined;
  /** The registered act adapters; the route step chooses among them, the act step dispatches by `memo.route`. */
  destinations?: Destinations | undefined;
  herd?: Herd | undefined;
  decider?: Decider | undefined;
  summarizer?: Summarizer | undefined;
  notifier: Notifier;
}): Partial<Record<HandlerStep, StepHandler>> {
  const {
    store,
    audio,
    transcriber,
    destinations = {},
    herd,
    decider,
    summarizer,
    notifier,
  } = deps;
  /** The raw transcript, minus a spoken routing prefix when one routed the memo. */
  const delivered = (memo: Memo, step: HandlerStep) =>
    deliveredTranscript({
      transcript: required(memo.transcript, "transcript", step),
      decisions: store.listRouteDecisions(memo.id),
    });
  const registered = (Object.keys(destinations) as DestinationName[]).filter(
    (name) => destinations[name],
  );
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

  // Without a destination there is nothing to route to: the memo waits at `transcribed` until one is configured.
  if (registered.length > 0) {
    handlers.route = async ({ memo }) => {
      const transcript = required(memo.transcript, "transcript", "route");
      const decision = await route({
        memoId: memo.id,
        mode: memo.mode,
        transcript,
        destinations: registered,
        herd,
        decider,
      });
      const routed = decision.outcome === "routed";
      getActiveSpan().setAttributes({
        route: decision.destination,
        "route.source": decision.source,
        "route.confidence": decision.confidence,
        cost_usd: decision.costUsd,
      });
      log("route.decided", {
        memo: memo.id,
        source: decision.source,
        destination: decision.destination,
        confidence: decision.confidence,
        outcome: decision.outcome,
        reason: decision.reason,
      });
      const { usage, ...row } = decision;
      return {
        ...(!routed && { outcome: "needs_route" as const }),
        patch: {
          ...(routed && { route: decision.destination }),
          routeDecision: row,
        },
        ...(usage !== undefined && { usage }),
        ...(decision.costUsd !== null && { costUsd: decision.costUsd }),
      };
    };

    handlers.act = async ({ memo }) => {
      const transcript = delivered(memo, "act");
      const name = required(memo.route, "route", "act");
      const destination = destinations[name as DestinationName];
      if (!destination) throw new Error(`act: no destination registered for route "${name}"`);
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
        transcript: delivered(memo, "summarize"),
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
