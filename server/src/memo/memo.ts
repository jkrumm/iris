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

export interface Memo {
  id: string;
  mode: MemoMode;
  device: string;
  startedAt: string;
  state: MemoState;
  failedStep: Step | null;
  error: string | null;
  segmentCount: number | null;
  createdAt: string;
  updatedAt: string;
}

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
