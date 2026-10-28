export const MEMO_MODES = ["auto", "journal", "hermes", "tab", "chat"] as const;
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

/** A handler can park the memo instead of advancing it; only `route` and `act` may. */
export type StepOutcome = "needs_route";

/** The triage result: a notification headline, a longer detail line and 1–2 spoken sentences. */
export interface Summary {
  headline: string;
  detail: string;
  spoken: string;
}

export const ASSET_SCHEMES = ["light", "dark"] as const;
export type AssetScheme = (typeof ASSET_SCHEMES)[number];
export const ASSET_FORMATS = ["svg", "png"] as const;
export type AssetFormat = (typeof ASSET_FORMATS)[number];

/** One stored file of a rendered reply block; `id` names the file under the memo (`GET /memos/:id/assets/:assetId`). */
export interface ReplyAsset {
  id: string;
  /** Zero-based position among the reply's ```mermaid fences, in document order. */
  block: number;
  format: AssetFormat;
  scheme: AssetScheme;
  /** The diagram's size in points (the PNG is a multiple of it). */
  width: number;
  height: number;
}

/** A Mermaid block of the reply with all four renderings: the asset ids by format and colour scheme. */
export interface ReplyBlock {
  index: number;
  kind: "mermaid";
  width: number;
  height: number;
  svg: Record<AssetScheme, string>;
  png: Record<AssetScheme, string>;
}

/** Groups stored assets into blocks, ordered by index; a block missing one of its four renderings is dropped. */
export function groupReplyBlocks(assets: readonly ReplyAsset[]): ReplyBlock[] {
  const byBlock = new Map<number, ReplyAsset[]>();
  for (const asset of assets)
    byBlock.set(asset.block, [...(byBlock.get(asset.block) ?? []), asset]);
  const blocks: ReplyBlock[] = [];
  for (const [index, files] of [...byBlock].toSorted(([a], [b]) => a - b)) {
    const idOf = (format: AssetFormat, scheme: AssetScheme) =>
      files.find((f) => f.format === format && f.scheme === scheme)?.id;
    const [svgLight, svgDark, pngLight, pngDark] = [
      idOf("svg", "light"),
      idOf("svg", "dark"),
      idOf("png", "light"),
      idOf("png", "dark"),
    ];
    const first = files[0];
    if (!first || !svgLight || !svgDark || !pngLight || !pngDark) continue;
    blocks.push({
      index,
      kind: "mermaid",
      width: first.width,
      height: first.height,
      svg: { light: svgLight, dark: svgDark },
      png: { light: pngLight, dark: pngDark },
    });
  }
  return blocks;
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
  /** The reply's Mermaid blocks that rendered, by block index; blocks that did not render stay code blocks and are absent. */
  replyBlocks: ReplyBlock[];
  summary: Summary | null;
  /**
   * The Hermes session (chat or not) the memo ran in: set by `act` (a fresh memo's own session, so equal to its id), or at
   * creation for a memo that continues a thread. Null before then and for other destinations.
   */
  threadId: string | null;
  /**
   * Derived from the decision log, not a column: while the memo is `needs_route`, why it parked and
   * (low-confidence parks) the model's best guess. Absent in every other state.
   */
  routeReason?: string;
  routeSuggestion?: string;
  /** User flags (swipe actions): handled, starred, and when it was archived. None of them affects the pipeline. */
  done: boolean;
  favorite: boolean;
  archivedAt: string | null;
  /** Soft delete: set by `DELETE`, cleared by restore; the sweeper purges the memo `PURGE_AFTER_MS` later. */
  deletedAt: string | null;
  createdAt: string;
  updatedAt: string;
}

/** How long a soft-deleted memo stays restorable before the sweeper purges it. The one definition. */
export const PURGE_AFTER_MS = 10 * 60 * 1000;

/** When a soft-deleted memo is purged (ISO), or null for a memo that is not deleted. */
export function purgeAt(memo: Pick<Memo, "deletedAt">): string | null {
  return memo.deletedAt === null
    ? null
    : new Date(Date.parse(memo.deletedAt) + PURGE_AFTER_MS).toISOString();
}

/** Only a memo the pipeline is done with may be deleted: the runner never touches it again. */
export function isDeletable(state: MemoState): boolean {
  return state === "notified" || state === "failed" || state === "needs_route";
}

/** The user flags `PATCH /memos/:id` sets; an absent key is left as it is. */
export interface MemoFlags {
  done?: boolean | undefined;
  favorite?: boolean | undefined;
  archived?: boolean | undefined;
}

/**
 * Typed instead of spoken: such a memo is created past `receiving` and never passes `received`, so it
 * has no segment count. The one definition; the wire carries it as `typed`.
 */
export function isTyped(memo: Pick<Memo, "segmentCount" | "state">): boolean {
  return memo.segmentCount === null && memo.state !== "receiving";
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
  /** Source `prefix`: the leading transcript words the spoken prefix covers, so `act` cuts exactly those. Absent on older rows. */
  prefixWords?: number;
}

export interface RouteDecisionRecord extends RouteDecisionInput {
  id: number;
  memoId: string;
  createdAt: string;
}

/** The memo columns a handler may set when its step completes. */
export type MemoColumnPatch = Partial<
  Pick<
    Memo,
    | "audioSeconds"
    | "transcript"
    | "route"
    | "destinationRef"
    | "replyText"
    | "summary"
    | "threadId"
  >
>;

/**
 * The thread a memo was created to continue, else null. A fresh memo's session is named after the memo, so its `threadId`
 * equals its id once `act` ran and says nothing about what the client asked for.
 */
export function continuedThread(memo: Pick<Memo, "id" | "threadId">): string | null {
  return memo.threadId !== null && memo.threadId !== memo.id ? memo.threadId : null;
}

export const THREAD_KINDS = ["chat", "hermes"] as const;
export type ThreadKind = (typeof THREAD_KINDS)[number];

/** A Hermes session that one or more memos ran in; `kind` is Iris's own record (`chat` or a normal task). */
export interface Thread {
  id: string;
  kind: ThreadKind;
  title: string;
  createdAt: string;
  updatedAt: string;
  lastMemoId: string | null;
}
/** First characters of a thread's first transcript. */
export const THREAD_TITLE_MAX = 60;

/** The first ~60 characters of a transcript, whitespace collapsed: a thread's title. */
export function threadTitle(transcript: string): string {
  const text = transcript.replace(/\s+/g, " ").trim();
  return text.length > THREAD_TITLE_MAX
    ? `${text.slice(0, THREAD_TITLE_MAX - 1).trimEnd()}…`
    : text;
}

/** One turn of a thread as Iris recorded it: what was said (the memo's transcript) or answered (its reply). */
export interface ThreadMessage {
  memoId: string;
  role: "user" | "assistant";
  /** Markdown for an assistant message. */
  content: string;
  createdAt: string;
}

/**
 * A thread's messages from its memos, in the memos' order: each memo contributes its transcript as a `user` message and, once
 * `act` returned one, its reply as an `assistant` message. A memo that has no transcript yet, or whose reply is empty (the
 * destination did not answer, or the memo failed before `act`), contributes only what it has. `repliedAt` is when `act` finished
 * (the reply's time); the memo's last update stands in when it is unknown.
 */
export function threadMessages(turns: { memo: Memo; repliedAt: string | null }[]): ThreadMessage[] {
  return turns.flatMap(({ memo, repliedAt }): ThreadMessage[] => [
    ...(memo.transcript && memo.transcript.trim() !== ""
      ? [
          {
            memoId: memo.id,
            role: "user" as const,
            content: memo.transcript,
            createdAt: memo.createdAt,
          },
        ]
      : []),
    ...(memo.replyText && memo.replyText.trim() !== ""
      ? [
          {
            memoId: memo.id,
            role: "assistant" as const,
            content: memo.replyText,
            createdAt: repliedAt ?? memo.updatedAt,
          },
        ]
      : []),
  ]);
}

/**
 * A thread as the destination reports it, which alone decides its identity: upserted into `threads`, and `memos.thread_id`
 * set to its id with the step's patch.
 */
export interface ThreadUpsert {
  /** The destination's session id (Hermes). */
  id: string;
  kind: ThreadKind;
  /** Only used when the thread is new; a thread keeps the title of its first transcript. */
  title: string;
}

/**
 * What a step writes atomically with its completion: memo columns, and for a step that routes or
 * parks (`route`, `act`) a decision-log row, and for `act` into a thread-keeping destination the thread it ran in (`thread` upserts the row; `memos.thread_id` is set from it).
 */
export type MemoPatch = MemoColumnPatch & {
  routeDecision?: RouteDecisionInput;
  thread?: ThreadUpsert;
};

export interface StepRecord {
  step: Step;
  status: "running" | "done" | "failed";
  startedAt: string;
  finishedAt: string | null;
  error: string | null;
  usage: unknown;
  costUsd: number | null;
  /** Tries the step has used, 1 when it never needed a retry. */
  attempts: number;
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
  act: { from: "routed", to: "acted", park: "needs_route" },
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

/** After `act`: a route can no longer change the outcome, so an answer is only recorded as a correction. */
export function isCorrectable(state: MemoState): boolean {
  return state === "acted" || state === "summarized" || state === "notified";
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
