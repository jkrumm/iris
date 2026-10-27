import type { MemoMode, RouteDecisionInput } from "../memo/memo.js";
import type { Decider } from "../ports/decider.js";
import { hasChoice, type DestinationName } from "../ports/destination.js";
import type { Herd, HerdTab } from "../ports/herd.js";
import { log } from "../telemetry/log.js";
import { fold, parsePrefix } from "./prefix.js";

/** At or above this confidence the model's answer routes the memo; below it the memo parks. */
export const CONFIDENCE_THRESHOLD = 0.8;
/** Transcript characters the decision model sees. */
const STATE_TRANSCRIPT_MAX = 4000;
const REASON_MAX = 200;
/** The park reason of a herdr route that names no tab and has no single live tab to default to. */
export const WHICH_TAB = "which tab?";

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

/**
 * The live tab a spoken name points at: it matches a tab label or a workspace (repo) label, ignoring case
 * and diacritics. The spoken name is one word (see `parsePrefix`), so a label with a space never matches. Without a name (mode `tab`) the only live tab is the answer. Anything but
 * exactly one match is a reason to park.
 */
async function resolveTab(params: {
  spoken: string | null;
  herd: Herd | undefined;
  memoId: string;
}): Promise<{ tab: string } | { reason: string }> {
  const { spoken, herd, memoId } = params;
  const tabs = await liveTabs(herd, memoId);
  if (tabs === null) return { reason: "herd unavailable" };

  const matches =
    spoken === null
      ? tabs
      : tabs.filter((tab) => {
          const name = fold(spoken);
          return [tab.label, tab.repo].some((c) => fold(c) === name);
        });
  const [first] = matches;
  if (first && matches.length === 1) return { tab: first.id };
  if (spoken === null) return { reason: WHICH_TAB };
  const what = clip(`"${spoken}"`);
  return { reason: matches.length === 0 ? `no tab named ${what}` : `several tabs match ${what}` };
}

/**
 * A destination named by mode, prefix or as the only one registered: routed when registered, else parked with a
 * reason. Herdr needs a tab on every one of these paths.
 */
async function named(params: {
  source: "mode" | "prefix" | "default";
  destination: DestinationName;
  spokenTab: string | null;
  registered: readonly DestinationName[];
  herd: Herd | undefined;
  memoId: string;
}): Promise<RouteDecision> {
  const { source, destination, spokenTab, registered, herd, memoId } = params;
  if (!registered.includes(destination)) {
    return decision({
      source,
      outcome: "needs_route",
      reason: `${destination} not available`,
    });
  }
  if (destination !== "herdr") {
    return decision({ source, outcome: "routed", destination, confidence: 1 });
  }
  const resolved = await resolveTab({ spoken: spokenTab, herd, memoId });
  if ("reason" in resolved) {
    return decision({ source, outcome: "needs_route", destination, reason: resolved.reason });
  }
  return decision({ source, outcome: "routed", destination, tab: resolved.tab, confidence: 1 });
}

const herdLine = (tab: HerdTab) => `- ${tab.id}: ${tab.repo} / ${tab.label} (${tab.agentState})`;

/** Live tabs; null when there is no herd or it cannot be read. */
async function liveTabs(herd: Herd | undefined, memoId: string): Promise<HerdTab[] | null> {
  if (!herd) return null;
  try {
    return await herd.snapshot();
  } catch (err) {
    log("route.herd_unavailable", { memo: memoId, error: errorMessage(err) });
    return null;
  }
}

async function decide(input: RouteInput & { decider: Decider }): Promise<RouteDecision> {
  const { memoId, transcript, destinations, decider } = input;
  const herdrChoice = destinations.includes("herdr");
  const tabs = herdrChoice ? ((await liveTabs(input.herd, memoId)) ?? []) : [];
  const state = [
    transcript.slice(0, STATE_TRANSCRIPT_MAX),
    ...(tabs.length > 0 ? ["", "Open terminal tabs:", ...tabs.map(herdLine)] : []),
  ].join("\n");

  // An infrastructure failure (transport, hang guard, off-schema answer) propagates: the step fails
  // and `POST /retry {from: route}` recovers it. Only a model answer that cannot route parks the memo.
  const answer = await decider.decide({
    memoId,
    state,
    destinations: Object.fromEntries(destinations.map((name) => [name, DESCRIPTIONS[name]])),
    tabs:
      tabs.length > 0
        ? Object.fromEntries(tabs.map((tab) => [tab.id, `${tab.repo} / ${tab.label}`]))
        : undefined,
  });

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
 * Decides where a transcribed memo goes. In order: an explicit mode, a spoken prefix (a spoken tab name is
 * resolved against the live herd to a tab id), the only registered destination, the decision model. A memo that cannot be routed is a `needs_route` decision with a reason;
 * a failing decider throws, so the step fails and can be retried.
 */
export async function route(input: RouteInput): Promise<RouteDecision> {
  const { mode, transcript, destinations } = input;
  if (mode !== "auto") {
    return named({
      source: "mode",
      destination: MODE_DESTINATION[mode],
      spokenTab: null,
      registered: destinations,
      herd: input.herd,
      memoId: input.memoId,
    });
  }

  const prefix = parsePrefix(transcript);
  if (prefix) {
    return named({
      source: "prefix",
      destination: prefix.destination,
      spokenTab: prefix.tab ?? null,
      registered: destinations,
      herd: input.herd,
      memoId: input.memoId,
    });
  }

  if (!hasChoice(destinations)) {
    const [only] = destinations;
    if (!only) {
      return decision({
        source: "default",
        outcome: "needs_route",
        reason: "no destination available",
      });
    }
    return named({
      source: "default",
      destination: only,
      spokenTab: null,
      registered: destinations,
      herd: input.herd,
      memoId: input.memoId,
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
