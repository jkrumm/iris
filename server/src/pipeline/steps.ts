import { createKeyedQueue, KeyedQueueTimeout } from "../memo/keyed-queue.js";
import {
  continuedThread,
  type HandlerStep,
  type Memo,
  type RouteDecisionInput,
  type Summary,
} from "../memo/memo.js";
import type { StepHandler } from "../memo/runner.js";
import type { MemoStore } from "../memo/store.js";
import type { AudioStore } from "../ports/audio.js";
import type { Decider } from "../ports/decider.js";
import {
  isDestinationName,
  registeredDestinations,
  type DestinationName,
  TabGoneError,
  type Destinations,
} from "../ports/destination.js";
import type { Herd } from "../ports/herd.js";
import type { Notifier } from "../ports/notifier.js";
import type { Summarizer } from "../ports/summarizer.js";
import type { Transcriber } from "../ports/transcriber.js";
import { deliveredTranscript, route, WHICH_TAB, type RouteDecision } from "../routing/index.js";
import { log } from "../telemetry/log.js";
import { getActiveSpan } from "../telemetry/otel.js";

// Each step is a pure function of (memo, ports): it reads what earlier steps stored on the memo,
// returns its own result as a patch and never writes the store itself, so it is safe to re-run.

// How long a turn waits for the turn ahead of it in the same Hermes thread: the size of a hang guard, since a turn has
// an idle watchdog but no wall-clock cap.
const THREAD_WAIT_MS = 1_800_000;

const HEADLINE_MAX = 60;
const DETAIL_MAX = 240;

const clip = (text: string, max: number) =>
  text.length > max ? `${text.slice(0, max - 1).trimEnd()}…` : text;

/** Journal and herdr never produce an answer worth a model call: the summary is a fixed phrase plus an excerpt. */
function templatedSummary(params: {
  destination: "journal" | "herdr";
  transcript: string;
  /** The herdr tab the memo went to, as far as the live herd still knows it. */
  tab: { repo: string; label: string } | null;
}): Summary {
  const { destination, transcript, tab } = params;
  const detail = clip(transcript.replace(/\s+/g, " ").trim(), DETAIL_MAX);
  if (destination === "journal") {
    return { headline: "Saved to journal", detail, spoken: "Saved to your journal." };
  }
  const target = tab ? `${tab.repo} / ${tab.label}` : "tab";
  return {
    headline: clip(`Sent to ${target}`, HEADLINE_MAX),
    detail,
    spoken: `Sent to ${tab ? `${tab.repo} ${tab.label}` : "the tab"}.`,
  };
}

/** The route of a memo that continues a thread: forced to `hermes`, no model call. */
function continuationRoute(registered: readonly DestinationName[]): RouteDecision {
  if (!registered.includes("hermes")) {
    throw new Error("route: a thread continues in Hermes, which is not registered");
  }
  return {
    source: "mode",
    destination: "hermes",
    tab: null,
    confidence: null,
    model: null,
    costUsd: null,
    reason: null,
    outcome: "routed",
  };
}

const errorMessage = (err: unknown) => (err instanceof Error ? err.message : String(err));

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

  // Turns into one Hermes session run one at a time: a second memo for the same thread waits for the first's reply, up
  // to `THREAD_WAIT_MS`; past that it fails and names the turn ahead (`POST /retry` re-queues it).
  const inThread = createKeyedQueue({ maxWaitMs: THREAD_WAIT_MS });
  /** The raw transcript, minus a spoken routing prefix when one routed the memo. */
  const delivered = (memo: Memo, step: HandlerStep) =>
    deliveredTranscript({
      transcript: required(memo.transcript, "transcript", step),
      decisions: store.listRouteDecisions(memo.id),
    });
  const registered = registeredDestinations(destinations);
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
      // A reply into a thread goes to the Hermes session that holds it, whatever the mode or the words say.
      const decision: RouteDecision = continuedThread(memo)
        ? continuationRoute(registered)
        : await route({
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
      const destination = isDestinationName(name) ? destinations[name] : undefined;
      if (!destination) throw new Error(`act: no destination registered for route "${name}"`);

      // The decision that routed the memo names the tab; an answer to a park replaces the one before it.
      const routedBy = store
        .listRouteDecisions(memo.id)
        .findLast((d) => d.outcome === "routed" && d.source !== "correction");
      const tab = name === "herdr" ? (routedBy?.tab ?? undefined) : undefined;
      // Both ways a herdr memo cannot be delivered park it for a new answer: no tab on the route, or a tab that is gone.
      const park = (reason: string, parkedTab: string | null) => {
        log("act.parked", { memo: memo.id, tab: parkedTab, reason });
        const parked: RouteDecisionInput = {
          source: routedBy?.source ?? "default",
          outcome: "needs_route",
          destination: name,
          tab: parkedTab,
          confidence: null,
          model: null,
          costUsd: null,
          reason,
        };
        return { outcome: "needs_route" as const, patch: { routeDecision: parked } };
      };
      if (name === "herdr" && tab === undefined) return park(WHICH_TAB, null);

      // A continuation delivers into its thread's session; the thread, not the memo's mode, says whether it is a chat
      // (Hermes does not keep the no-side-effects message, so every turn of a chat thread sends it again).
      const threadId = name === "hermes" ? continuedThread(memo) : null;
      const chat =
        name === "hermes" &&
        (threadId ? store.getThread(threadId)?.kind === "chat" : memo.mode === "chat");
      let delivery;
      try {
        const deliver = () =>
          destination.deliver({
            memoId: memo.id,
            transcript,
            ...(tab !== undefined && { tab }),
            ...(chat && { chat }),
            ...(threadId && { threadId }),
          });
        delivery = await (threadId ? inThread(threadId, deliver, `memo ${memo.id}`) : deliver());
      } catch (err) {
        if (err instanceof TabGoneError) return park(err.message, err.tab);
        if (err instanceof KeyedQueueTimeout) {
          throw new Error(
            `thread ${err.key} is busy: waited ${err.waitedMs} ms behind ${err.ahead}, which has not finished`,
            { cause: err },
          );
        }
        throw err;
      }
      getActiveSpan().setAttributes({
        reply_chars: delivery.replyText.length,
        cost_usd: delivery.costUsd,
      });
      return {
        patch: {
          destinationRef: delivery.ref,
          replyText: delivery.replyText,
          ...(delivery.thread && { thread: delivery.thread }),
        },
        usage: delivery.usage,
        ...(delivery.costUsd !== undefined && { costUsd: delivery.costUsd }),
      };
    };
  }

  /** The herd for a summary's tab name; a herd that cannot be read only costs the name. */
  const liveTabs = async (memoId: string) => {
    if (!herd) return [];
    try {
      return await herd.snapshot();
    } catch (err) {
      log("summarize.herd_unavailable", { memo: memoId, error: errorMessage(err) });
      return [];
    }
  };

  // Always present: journal and herdr are summarized from a template, only the model-backed routes need the port.
  handlers.summarize = async ({ memo }) => {
    const name = required(memo.route, "route", "summarize");
    const transcript = delivered(memo, "summarize");
    if (name === "journal" || name === "herdr") {
      const tabs = name === "herdr" ? await liveTabs(memo.id) : [];
      const tab = tabs.find((t) => t.id === memo.destinationRef) ?? null;
      return { patch: { summary: templatedSummary({ destination: name, transcript, tab }) } };
    }
    if (!summarizer) throw new Error(`summarize: no summarizer configured for route "${name}"`);
    const result = await summarizer.summarize({
      memoId: memo.id,
      route: name,
      transcript,
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

  handlers.notify = async ({ memo }: { memo: Memo }) => {
    const summary = required(memo.summary, "summary", "notify");
    await notifier.notify({ memo, summary });
    return {};
  };

  return handlers;
}
