export const MEMO_MODES = ["auto", "journal", "hermes", "tab"] as const;
export type MemoMode = (typeof MEMO_MODES)[number];

export const MEMO_STATES = [
  "receiving",
  "received",
  "transcribed",
  "routed",
  "needs_route",
  "acted",
  "summarized",
  "notified",
  "failed",
] as const;
export type MemoState = (typeof MEMO_STATES)[number];

export const STEPS = ["ingest", "transcribe", "route", "act", "summarize", "notify"] as const;
export type Step = (typeof STEPS)[number];
/** Steps a handler implements; `ingest` is driven by the upload `complete` call. */
export type HandlerStep = Exclude<Step, "ingest">;

/** A handler can park the memo instead of advancing it; only `route` may. */
export type StepOutcome = "needs_route";

/** The triage result: a notification headline, a longer detail line and 1–2 spoken sentences. */
export interface Summary {
  headline: string;
  detail: string;
  spoken: string;
}

export interface Memo {
  id: string;
  mode: MemoMode;
  device: string;
  startedAt: string;
  state: MemoState;
  failedStep: Step | null;
  error: string | null;
  segmentCount: number | null;
  /** Written by the steps; null until the step that produces it has run. */
  audioSeconds: number | null;
  transcript: string | null;
  /** The destination name (`hermes`, `journal`, `herdr`); null until the route step has routed it. */
  route: string | null;
  destinationRef: string | null;
  replyText: string | null;
  summary: Summary | null;
  /**
   * Derived from the decision log, not a column: while the memo is `needs_route`, why it parked and
   * (low-confidence parks) the model's best guess. Absent in every other state.
   */
  routeReason?: string;
  routeSuggestion?: string;
  createdAt: string;
  updatedAt: string;
}

export const ROUTE_SOURCES = [
  "mode",
  "prefix",
  "decide",
  "default",
  "answer",
  "correction",
] as const;
export type RouteSource = (typeof ROUTE_SOURCES)[number];
export const ROUTE_OUTCOMES = ["routed", "needs_route"] as const;
export type RouteOutcome = (typeof ROUTE_OUTCOMES)[number];

/** One row of the routing decision log, as a handler reports it. */
export interface RouteDecisionInput {
  source: RouteSource;
  /** The chosen destination; on a low-confidence park the model's best guess, null when nothing was chosen. */
  destination: string | null;
  tab: string | null;
  confidence: number | null;
  model: string | null;
  costUsd: number | null;
  /** Why the memo parked; null when routed. */
  reason: string | null;
  outcome: RouteOutcome;
}

export interface RouteDecisionRecord extends RouteDecisionInput {
  id: number;
  memoId: string;
  createdAt: string;
}

/** The memo columns a handler may set when its step completes. */
export type MemoColumnPatch = Partial<
  Pick<Memo, "audioSeconds" | "transcript" | "route" | "destinationRef" | "replyText" | "summary">
>;

/** What a step writes atomically with its completion: memo columns, and for `route` its decision-log row. */
export type MemoPatch = MemoColumnPatch & { routeDecision?: RouteDecisionInput };

export interface StepRecord {
  step: Step;
  status: "running" | "done" | "failed";
  startedAt: string;
  finishedAt: string | null;
  error: string | null;
  usage: unknown;
  costUsd: number | null;
}

interface Transition {
  from: MemoState;
  to: MemoState;
  /** Alternative target when the handler reports `needs_route`. */
  park?: MemoState;
}

const TRANSITIONS: Record<Step, Transition> = {
  ingest: { from: "receiving", to: "received" },
  transcribe: { from: "received", to: "transcribed" },
  route: { from: "transcribed", to: "routed", park: "needs_route" },
  act: { from: "routed", to: "acted" },
  summarize: { from: "acted", to: "summarized" },
  notify: { from: "summarized", to: "notified" },
};

const HANDLER_STEPS: readonly HandlerStep[] = ["transcribe", "route", "act", "summarize", "notify"];

export class IllegalTransitionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "IllegalTransitionError";
  }
}

/** The handler step to run from `state`, or null when the runner has nothing to do there. */
export function nextStep(state: MemoState): HandlerStep | null {
  return HANDLER_STEPS.find((step) => TRANSITIONS[step].from === state) ?? null;
}

/** The runner stops for good here. */
export function isTerminal(state: MemoState): boolean {
  return state === "notified" || state === "failed";
}

/** A result long-poll can answer. `needs_route` is parked awaiting a user choice. */
export function isResultReady(state: MemoState): boolean {
  return isTerminal(state) || state === "needs_route";
}

/** The state a retry from `step` resets the memo to. */
export function stateBefore(step: Step): MemoState {
  return TRANSITIONS[step].from;
}

export function stepIndex(step: Step): number {
  return STEPS.indexOf(step);
}

/** `step` and every later step, in pipeline order. */
export function stepsFrom(step: Step): Step[] {
  return STEPS.slice(stepIndex(step));
}

/** The state after `step` succeeds from `state`; throws when the move is not in the table. */
export function advance(params: {
  state: MemoState;
  step: Step;
  outcome?: StepOutcome | undefined;
}): MemoState {
  const { state, step, outcome } = params;
  const t = TRANSITIONS[step];
  if (state !== t.from) {
    throw new IllegalTransitionError(`step ${step} cannot run from state ${state}`);
  }
  if (!outcome) return t.to;
  if (!t.park) throw new IllegalTransitionError(`step ${step} cannot yield ${outcome}`);
  return t.park;
}
