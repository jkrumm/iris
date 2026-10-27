import type { MemoMode, RouteDecisionInput } from "../memo/memo.js";
import type { Decider } from "../ports/decider.js";
import type { DestinationName } from "../ports/destination.js";
import type { Herd, HerdTab } from "../ports/herd.js";
import { log } from "../telemetry/log.js";
import { parsePrefix } from "./prefix.js";

/** At or above this confidence the model's answer routes the memo; below it the memo parks. */
export const CONFIDENCE_THRESHOLD = 0.8;
/** Transcript characters the decision model sees. */
const STATE_TRANSCRIPT_MAX = 4000;
const REASON_MAX = 200;

const DESCRIPTIONS: Record<DestinationName, string> = {
  journal:
    "A personal note, reflection or diary entry for the speaker's own journal; nothing to act on.",
  hermes: "A request, question or task for the Hermes assistant to answer or carry out.",
  herdr: "An instruction for a coding agent running in one of the open terminal tabs.",
};

const MODE_DESTINATION: Record<Exclude<MemoMode, "auto">, DestinationName> = {
  journal: "journal",
  hermes: "hermes",
  tab: "herdr",
};

export interface RouteDecision extends RouteDecisionInput {
  usage?: unknown;
}

export interface RouteInput {
  memoId: string;
  mode: MemoMode;
  transcript: string;
  /** The destinations with a registered act adapter; only these are choices. */
  destinations: readonly DestinationName[];
  herd?: Herd | undefined;
  decider?: Decider | undefined;
}

const errorMessage = (err: unknown) => (err instanceof Error ? err.message : String(err));

const clip = (text: string) => (text.length > REASON_MAX ? `${text.slice(0, REASON_MAX)}…` : text);

function decision(
  fields: Partial<RouteDecisionInput> & Pick<RouteDecisionInput, "source" | "outcome">,
): RouteDecision {
  return {
    destination: null,
    tab: null,
    confidence: null,
    model: null,
    costUsd: null,
    reason: null,
    ...fields,
  };
}

/** A destination named by mode or prefix: routed when registered, else parked with a reason. */
function named(params: {
  source: "mode" | "prefix";
  destination: DestinationName;
  tab: string | null;
  registered: readonly DestinationName[];
}): RouteDecision {
  const { source, destination, tab, registered } = params;
  if (!registered.includes(destination)) {
    return decision({
      source,
      outcome: "needs_route",
      reason: `${destination} not available`,
    });
  }
  return decision({ source, outcome: "routed", destination, tab, confidence: 1 });
}

const herdLine = (tab: HerdTab) => `- ${tab.id}: ${tab.repo} / ${tab.label} (${tab.agentState})`;

/** Live tabs, or none when herdr is not a choice or the herd cannot be read. */
async function liveTabs(herd: Herd | undefined, memoId: string): Promise<HerdTab[]> {
  if (!herd) return [];
  try {
    return await herd.snapshot();
  } catch (err) {
    log("route.herd_unavailable", { memo: memoId, error: errorMessage(err) });
    return [];
  }
}

async function decide(input: RouteInput & { decider: Decider }): Promise<RouteDecision> {
  const { memoId, transcript, destinations, decider } = input;
  const herdrChoice = destinations.includes("herdr");
  const tabs = herdrChoice ? await liveTabs(input.herd, memoId) : [];
  const state = [
    transcript.slice(0, STATE_TRANSCRIPT_MAX),
    ...(tabs.length > 0 ? ["", "Open terminal tabs:", ...tabs.map(herdLine)] : []),
  ].join("\n");

  let answer: Awaited<ReturnType<Decider["decide"]>>;
  try {
    answer = await decider.decide({
      memoId,
      state,
      destinations: Object.fromEntries(destinations.map((name) => [name, DESCRIPTIONS[name]])),
      tabs:
        tabs.length > 0
          ? Object.fromEntries(tabs.map((tab) => [tab.id, `${tab.repo} / ${tab.label}`]))
          : undefined,
    });
  } catch (err) {
    log("route.decide_failed", { memo: memoId, error: errorMessage(err) });
    return decision({
      source: "decide",
      outcome: "needs_route",
      reason: clip(`decide failed: ${errorMessage(err)}`),
    });
  }

  const billed = {
    source: "decide" as const,
    model: answer.model,
    costUsd: answer.costUsd ?? null,
    ...(answer.usage !== undefined && { usage: answer.usage }),
  };
  const park = (reason: string, rest: Partial<RouteDecisionInput> = {}) =>
    decision({ ...billed, outcome: "needs_route", reason, ...rest });

  const picked = answer.destination;
  if (!picked) return park("decide refused");
  const destination = destinations.find((name) => name === picked.choice);
  if (!destination) return park(clip(`decide chose unknown destination "${picked.choice}"`));

  let tab: string | null = null;
  let confidence = picked.confidence;
  if (destination === "herdr") {
    const chosen = answer.tab;
    if (!chosen || !tabs.some((t) => t.id === chosen.choice)) {
      return park("herdr chosen without a live tab", { destination, confidence });
    }
    tab = chosen.choice;
    confidence = Math.min(confidence, chosen.confidence);
  }
  if (confidence < CONFIDENCE_THRESHOLD) {
    return park(`low confidence (${confidence.toFixed(2)})`, { destination, tab, confidence });
  }
  return decision({ ...billed, outcome: "routed", destination, tab, confidence });
}

/**
 * Decides where a transcribed memo goes. In order: an explicit mode, a spoken prefix, the only registered
 * destination, the decision model. Never throws: every fallback is a `needs_route` decision with a reason.
 */
export async function route(input: RouteInput): Promise<RouteDecision> {
  const { mode, transcript, destinations } = input;
  if (mode !== "auto") {
    return named({
      source: "mode",
      destination: MODE_DESTINATION[mode],
      tab: null,
      registered: destinations,
    });
  }

  const prefix = parsePrefix(transcript);
  if (prefix) {
    return named({
      source: "prefix",
      destination: prefix.destination,
      tab: prefix.tab ?? null,
      registered: destinations,
    });
  }

  const [only, second] = destinations;
  if (only && !second) {
    return decision({
      source: "default",
      outcome: "routed",
      destination: only,
      confidence: 1,
    });
  }
  if (!input.decider) {
    return decision({
      source: "decide",
      outcome: "needs_route",
      reason: "decide unavailable",
    });
  }
  return decide({ ...input, decider: input.decider });
}
