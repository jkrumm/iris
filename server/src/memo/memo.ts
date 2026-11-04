export const MEMO_MODES = ["auto", "journal", "hermes", "tab", "chat", "transcribe"] as const;
export type MemoMode = (typeof MEMO_MODES)[number];

/**
 * Every mode but `transcribe` hands the memo to Hermes (`act`); `transcribe` stops after the transcript. The other modes are the
 * owner's pick as the app offered it (`auto` and `hermes` pick nothing); Hermes decides either way.
 */
export const runsAct = (mode: MemoMode): boolean => mode !== "transcribe";

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

/** Every step a row of the timeline can name: `route` and `summarize` only on memos from before Hermes decided. */
export const STEPS = ["ingest", "transcribe", "route", "act", "summarize", "notify"] as const;
export type Step = (typeof STEPS)[number];
/** Steps a handler implements; `ingest` is driven by the upload `complete` call. */
export type HandlerStep = "transcribe" | "act" | "notify";

/** What Hermes reports for a turn (its ```iris block): a notification headline and one spoken sentence; `detail` is never set. */
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
  /** The destination name of a memo from before Hermes decided (`hermes`, `journal`, `herdr`); null on every new memo. */
  route: string | null;
  destinationRef: string | null;
  replyText: string | null;
  /** The reply's Mermaid blocks that rendered, by block index; blocks that did not render stay code blocks and are absent. */
  replyBlocks: ReplyBlock[];
  summary: Summary | null;
  /**
   * The Hermes session the memo ran in: set by `act` (a fresh memo's own session, so equal to its id), or at creation for a
   * memo that continues a thread. Null before then.
   */
  threadId: string | null;
  /** What Hermes called the memo (`normalizeKind`); null before `act`, in mode `transcribe` and when the reply carried no block. */
  kind: string | null;
  /** The tool names Hermes used in the turn (`normalizeActions`), first seen first; empty when none or unknown. */
  actions: string[];
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

/**
 * Only a memo the pipeline is done with, or has not started (`receiving`: a cancelled take), may be deleted:
 * the runner never touches it again.
 */
export function isDeletable(state: MemoState): boolean {
  return (
    state === "receiving" || state === "notified" || state === "failed" || state === "needs_route"
  );
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

/** The memo columns a handler may set when its step completes. */
export type MemoColumnPatch = Partial<
  Pick<
    Memo,
    | "audioSeconds"
    | "transcript"
    | "destinationRef"
    | "replyText"
    | "summary"
    | "threadId"
    | "kind"
    | "actions"
  >
>;

/**
 * The thread a memo was created to continue, else null. A fresh memo's session is named after the memo, so its `threadId`
 * equals its id once `act` ran and says nothing about what the client asked for.
 */
export function continuedThread(memo: Pick<Memo, "id" | "threadId">): string | null {
  return memo.threadId !== null && memo.threadId !== memo.id ? memo.threadId : null;
}

/** New threads are `hermes`; `chat` rows are from before the modes folded into one and stay readable. */
export const THREAD_KINDS = ["chat", "hermes"] as const;
export type ThreadKind = (typeof THREAD_KINDS)[number];

/** A Hermes session that one or more memos ran in. */
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
 * What a step writes atomically with its completion: memo columns, and for `act` the thread it ran in (`thread` upserts the row;
 * `memos.thread_id` is set from it).
 */
export type MemoPatch = MemoColumnPatch & {
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
}

/** The pipeline of every memo that runs `act`; the states `routed`, `summarized` and `needs_route` are only ever read (old rows). */
const TRANSITIONS: Partial<Record<Step, Transition>> = {
  ingest: { from: "receiving", to: "received" },
  transcribe: { from: "received", to: "transcribed" },
  act: { from: "transcribed", to: "acted" },
  notify: { from: "acted", to: "notified" },
};

const ACT_STEPS: readonly Step[] = ["ingest", "transcribe", "act", "notify"];

/** Mode `transcribe` stops after the transcript: `notify` runs straight from `transcribed`, no `act` row exists. */
const TRANSCRIBE_ONLY_STEPS: readonly Step[] = ["ingest", "transcribe", "notify"];

/** The steps a memo of `mode` goes through, in pipeline order; the pipeline of every memo, old ones included. */
export function stepsOf(mode: MemoMode): readonly Step[] {
  return runsAct(mode) ? ACT_STEPS : TRANSCRIBE_ONLY_STEPS;
}

function transitionOf(step: Step, mode: MemoMode): Transition {
  if (!stepsOf(mode).includes(step)) {
    throw new IllegalTransitionError(`step ${step} does not run in mode ${mode}`);
  }
  if (step === "notify" && !runsAct(mode)) return { from: "transcribed", to: "notified" };
  const transition = TRANSITIONS[step];
  if (!transition) throw new IllegalTransitionError(`step ${step} has no transition`);
  return transition;
}

const HANDLER_STEPS: readonly HandlerStep[] = ["transcribe", "act", "notify"];

export class IllegalTransitionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "IllegalTransitionError";
  }
}

/** The handler step to run from `state`, or null when the runner has nothing to do there. */
export function nextStep(params: { state: MemoState; mode: MemoMode }): HandlerStep | null {
  const { state, mode } = params;
  return (
    HANDLER_STEPS.find(
      (step) => stepsOf(mode).includes(step) && transitionOf(step, mode).from === state,
    ) ?? null
  );
}

/** The runner stops for good here. */
export function isTerminal(state: MemoState): boolean {
  return state === "notified" || state === "failed";
}

/** A result long-poll can answer. `needs_route` is a state of old rows only: nothing moves a memo there any more. */
export function isResultReady(state: MemoState): boolean {
  return isTerminal(state) || state === "needs_route";
}

/** The state a retry from `step` resets the memo to. */
export function stateBefore(params: { step: Step; mode: MemoMode }): MemoState {
  return transitionOf(params.step, params.mode).from;
}

export function stepIndex(step: Step): number {
  return STEPS.indexOf(step);
}

/** `step` and every later step of the full timeline (old `route` and `summarize` rows included), in order. */
export function stepsFrom(step: Step): Step[] {
  return STEPS.slice(stepIndex(step));
}

/**
 * The step a retry from `from` may start at, given where the memo failed: any step of its pipeline up to the failed one. An
 * old memo that failed at `route` or `summarize` (steps no pipeline has any more) counts as failed at the next step of the
 * pipeline, so it retries from `act` or `notify`.
 */
export function canRetryFrom(params: { from: Step; failedStep: Step; mode: MemoMode }): boolean {
  const { from, failedStep, mode } = params;
  const failedAt = stepsOf(mode).find((step) => stepIndex(step) >= stepIndex(failedStep));
  return failedAt !== undefined && stepIndex(from) <= stepIndex(failedAt);
}

/** The state after `step` succeeds from `state`; throws when the move is not in the table. */
export function advance(params: { state: MemoState; step: Step; mode: MemoMode }): MemoState {
  const { state, step, mode } = params;
  const t = transitionOf(step, mode);
  if (state !== t.from) {
    throw new IllegalTransitionError(`step ${step} cannot run from state ${state}`);
  }
  return t.to;
}

/** Longest `kind` the memo keeps, in code points. */
export const KIND_MAX = 24;
/** Longest headline kept from Hermes's block, in code points (the alert and Live Activity limit). */
export const HEADLINE_MAX = 60;
/** The most tool names a memo keeps. */
export const ACTIONS_MAX = 12;

/** Cuts to `max` code points with an ellipsis (trailing space dropped first), never splitting a surrogate pair. */
export function clipCodePoints(text: string, max: number): string {
  const points = Array.from(text);
  if (points.length <= max) return text;
  return `${points
    .slice(0, max - 1)
    .join("")
    .trimEnd()}…`;
}

/** A memo kind as stored and as `?kind=` filters: trimmed, lower-case, cut to `KIND_MAX` code points; null when nothing is left. */
export function normalizeKind(raw: string): string | null {
  const kind = Array.from(raw.trim().toLowerCase()).slice(0, KIND_MAX).join("").trim();
  return kind === "" ? null : kind;
}

/** Tool names, deduplicated in first-seen order and cut to `ACTIONS_MAX`; blank names are dropped. */
export function normalizeActions(names: readonly string[]): string[] {
  const seen = new Set<string>();
  for (const name of names) {
    const trimmed = name.trim();
    if (trimmed !== "") seen.add(trimmed);
  }
  return [...seen].slice(0, ACTIONS_MAX);
}
