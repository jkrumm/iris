import { t } from "elysia";
import { MEMO_ERROR_CODES } from "../memo/errors.js";
import { MEMO_MODES, MEMO_STATES, STEPS, THREAD_KINDS } from "../memo/memo.js";
import { APNS_ENVS, PLATFORMS } from "../ports/devices.js";
import { TELEMETRY_MAX_RECORDS } from "../telemetry/limits.js";

// Every request and response shape on the wire, in one file. Pure TypeBox (no Transform or custom
// codec) so they export to JSON Schema as they are. Response schemas mirror what `serialize.ts`
// emits field for field; the serializers stay the single mapping from domain to wire.
// Two deliberate exceptions to "pure": `ListQuery.limit` and `ResultQuery.wait` use `t.Numeric`
// because query strings arrive as text. `GET /events` (SSE) and the binary routes
// (`/memos/:id/audio`, `/memos/:id/speech`, `/memos/:id/assets/:assetId`) have no JSON success body; the guard's 401 is the
// plain text "Unauthorized".

// Elysia's own `t.Integer` is a Transform that also accepts numeric strings; this stays a plain number.
const Int = t.Number({ multipleOf: 1 });
const Nullable = t.Nullable;
const Step = t.UnionEnum([...STEPS]);
// `UnionEnum` defaults a missing value to its first member; a missing request `mode` must be a 400, not "auto".
const RequestMode = t.UnionEnum([...MEMO_MODES], { default: undefined });

// ── Errors ───────────────────────────────────────────────────────────────────

export const ErrorBody = t.Object({
  error: t.UnionEnum([...MEMO_ERROR_CODES]),
  message: t.String(),
});

export const MissingSegmentsError = t.Object({
  error: t.Literal("missing_segments"),
  message: t.String(),
  missing: t.Array(Int),
});

export const TooLargeError = t.Object({
  error: t.Literal("too_large"),
  message: t.String(),
  maxBytes: Int,
});

// ── Memos ────────────────────────────────────────────────────────────────────

const AssetIds = t.Object({ light: t.String(), dark: t.String() });

/**
 * A ```mermaid fence of the reply that rendered. `index` counts the reply's mermaid fences from zero in document order, so a
 * fence that did not render leaves a gap and stays a code block. `width` and `height` are points; the PNGs are drawn at twice
 * that (capped at 4096 px). The ids name files under `GET /memos/:id/assets/:assetId`.
 */
export const ReplyBlock = t.Object({
  index: Int,
  kind: t.Literal("mermaid"),
  width: Int,
  height: Int,
  svg: AssetIds,
  png: AssetIds,
});

export const Summary = t.Object({ headline: t.String(), detail: t.String(), spoken: t.String() });

const memoFields = {
  id: t.String(),
  mode: t.UnionEnum([...MEMO_MODES]),
  device: t.String(),
  startedAt: t.String(),
  state: t.UnionEnum([...MEMO_STATES]),
  failedStep: Nullable(Step),
  error: Nullable(t.String()),
  segmentCount: Nullable(Int),
  audioSeconds: Nullable(t.Number()),
  transcript: Nullable(t.String()),
  // The destination of a memo from before Hermes decided (`hermes`, `journal`, `herdr`); null on every newer one.
  route: Nullable(t.String()),
  destinationRef: Nullable(t.String()),
  replyText: Nullable(t.String()),
  // Present only when the reply has Mermaid blocks that rendered; omitted, never empty or null, otherwise.
  replyBlocks: t.Optional(t.Array(ReplyBlock)),
  summary: Nullable(Summary),
  // Present once the memo belongs to a Hermes session (chat or not): set when `act` ran in it, or at creation for a memo that
  // continues a thread; omitted, never null, otherwise.
  threadId: t.Optional(t.String()),
  // Present (and `true`) only for a typed memo, one created from text; omitted for a recording.
  typed: t.Optional(t.Literal(true)),
  // What Hermes called the memo (lower-case, at most 24 characters); omitted, never null, when it reported none.
  kind: t.Optional(t.String()),
  // The tool names Hermes used in the turn, first used first, at most 12, names only; omitted, never empty or null, otherwise.
  actions: t.Optional(t.Array(t.String())),
  // User flags, always present. `archived` is derived from the archive time, which stays server-side.
  done: t.Boolean(),
  favorite: t.Boolean(),
  archived: t.Boolean(),
  // Present only while the memo is soft-deleted: when it was deleted and when the purger removes it (10 minutes later);
  // `POST /memos/:id/restore` undoes the delete until then.
  deletedAt: t.Optional(t.String()),
  purgeAt: t.Optional(t.String()),
  createdAt: t.String(),
  updatedAt: t.String(),
};

export const Memo = t.Object(memoFields);

export const StepRecord = t.Object({
  step: Step,
  status: t.UnionEnum(["running", "done", "failed"]),
  startedAt: t.String(),
  finishedAt: Nullable(t.String()),
  error: Nullable(t.String()),
  usage: t.Unknown(),
  costUsd: Nullable(t.Number()),
  attempts: t.Number({ multipleOf: 1, minimum: 1 }),
});

/** The reply text streamed so far while `act` runs; a client drops `memo.delta` events of the same `attempt` with `seq` <= this one. */
const PartialReply = t.Object({ attempt: Int, seq: Int, text: t.String() });

/** The memo plus its step timeline; `segmentCount` is never null here. `partialReply` is present only while `act` has streamed visible text. */
export const MemoDetail = t.Object({
  ...memoFields,
  segmentCount: Int,
  steps: t.Array(StepRecord),
  partialReply: t.Optional(PartialReply),
});

// ── Threads ──────────────────────────────────────────────────────────────────

const ThreadKind = t.UnionEnum([...THREAD_KINDS]);

/** A Hermes session that memos ran in; `kind` is `hermes` for every new one, `chat` only on rows from before the modes folded into one. */
export const Thread = t.Object({
  id: t.String(),
  kind: ThreadKind,
  title: t.String(),
  createdAt: t.String(),
  updatedAt: t.String(),
  lastMemoId: Nullable(t.String()),
});

export const ThreadList = t.Object({ items: t.Array(Thread), nextCursor: Nullable(t.String()) });

/** One turn of the conversation, from the thread's own memos: a memo's transcript (`user`) or its reply (`assistant`, markdown). */
export const ThreadMessage = t.Object({
  memoId: t.String(),
  role: t.UnionEnum(["user", "assistant"]),
  content: t.String(),
  createdAt: t.String(),
});

/**
 * The thread, the memos that ran in it (oldest first) and the conversation they make up. Iris owns this data: nothing is read
 * from Hermes, so the response never depends on it.
 */
export const ThreadDetail = t.Object({
  thread: Thread,
  memos: t.Array(Memo),
  messages: t.Array(ThreadMessage),
});

/**
 * One page of history, newest first. Soft-deleted memos appear in none; archived ones only when the `archived` filter is on.
 */
export const MemoList = t.Object({
  items: t.Array(Memo),
  nextCursor: Nullable(t.String()),
});

export const MemoIdParams = t.Object({ id: t.String() });
export const AssetParams = t.Object({ id: t.String(), assetId: t.String() });
export const SegmentParams = t.Object({
  id: t.String(),
  n: t.String({ pattern: "^[0-9]{1,7}$" }),
});

// `threadId` continues that thread: the memo is delivered into its Hermes session (404 for an unknown thread).
export const CreateMemoBody = t.Object({
  id: t.String(),
  mode: RequestMode,
  startedAt: t.String(),
  threadId: t.Optional(t.String({ minLength: 1 })),
});
export const CreateTextMemoBody = t.Object({
  id: t.String(),
  mode: RequestMode,
  startedAt: t.String(),
  threadId: t.Optional(t.String({ minLength: 1 })),
  // No minLength/maxLength: the rule applies to the trimmed text, counted in Unicode code points, which a
  // schema length on the raw string cannot express. The service answers 400 for 0 or more than 20 000.
  text: t.String({
    description: "Trimmed server-side; 1 to 20000 Unicode code points after trimming, else 400.",
  }),
});
export const CompleteBody = t.Object({ segmentCount: Int });
// `UnionEnum` defaults a missing value to its first member; a missing `from` must be a 400, not "ingest".
export const RetryBody = t.Object({
  from: t.UnionEnum([...STEPS], {
    default: undefined,
    description:
      "The step to re-run from. 400 `bad_request` for a typed memo's `transcribe` (no recording) and for a step the memo's pipeline does not have (`transcribe`, `act`, `summarize`, `notify`; mode `transcribe` runs only `transcribe` and `notify`, an old memo that failed at `route` retries from `act`). 409 `bad_state` unless the memo `failed`, or is `notified` with `from: \"summarize\"` and its `summarize` step failed (the step is optional).",
  }),
});
/** `PATCH /memos/:id`: at least one flag, nothing else (400). */
export const FlagsBody = t.Object(
  {
    done: t.Optional(t.Boolean()),
    favorite: t.Optional(t.Boolean()),
    archived: t.Optional(t.Boolean()),
  },
  { additionalProperties: false, minProperties: 1 },
);

export const ListQuery = t.Object({
  limit: t.Optional(t.Numeric()),
  cursor: t.Optional(t.String()),
  // Search text: transcript and summary headline, case/umlaut-insensitive, each term a prefix, terms ANDed.
  q: t.Optional(t.String({ maxLength: 200 })),
  // `UnionEnum` defaults a missing value to its first member; an absent filter must stay absent.
  state: t.Optional(t.UnionEnum([...MEMO_STATES], { default: undefined })),
  // `favorite=true` keeps the favorites. `archived=true` lists only the archived memos (without it they are hidden).
  // Only `true` is a value; the filter is off by omitting it.
  favorite: t.Optional(t.Literal("true")),
  archived: t.Optional(t.Literal("true")),
  // The memo's kind, exact after the same normalisation as the stored one (trimmed, lower-case, cut to 24 characters).
  kind: t.Optional(t.String()),
  // `thread=true` keeps the memos of a conversation: a thread (Hermes session) with at least two live memos, i.e. one that was continued.
  thread: t.Optional(t.Literal("true")),
});
export const ThreadIdParams = t.Object({ id: t.String() });
export const ThreadListQuery = t.Object({
  limit: t.Optional(t.Numeric()),
  cursor: t.Optional(t.String()),
});
export const ResultQuery = t.Object({ wait: t.Optional(t.Numeric()) });

/** The `data:` payload of both `memo.updated` and `memo.done` on `GET /events`. */
export const MemoEventPayload = t.Object({
  id: t.String(),
  state: t.UnionEnum([...MEMO_STATES]),
  step: Nullable(Step),
  failedStep: Nullable(Step),
  error: Nullable(t.String()),
  at: t.String(),
});

/** `memo.delta` on `GET /events`: the next piece of the reply while `act` runs. A new `attempt` means act restarted: reset the buffer. `seq` starts at 1 per attempt. */
export const MemoDeltaPayload = t.Object({
  id: t.String(),
  attempt: Int,
  seq: Int,
  text: t.String(),
});

/** `memo.activity` on `GET /events`: a tool Hermes started (the action name, as in `actions`). */
export const MemoActivityPayload = t.Object({
  id: t.String(),
  attempt: Int,
  tool: t.String(),
});

// ── Devices ──────────────────────────────────────────────────────────────────

/** Identity is the authenticated device; `name` is only a display label. Omitted or empty tokens keep the stored ones, `null` clears. */
export const RegisterDeviceBody = t.Object({
  name: t.String({ minLength: 1 }),
  platform: t.UnionEnum([...PLATFORMS]),
  apnsToken: t.Optional(Nullable(t.String())),
  apnsEnv: t.Optional(Nullable(t.UnionEnum([...APNS_ENVS]))),
  pushToStartToken: t.Optional(Nullable(t.String())),
});

/** The registration as the client sees it: token presence, never the tokens. */
export const Device = t.Object({
  device: t.String(),
  name: t.String(),
  platform: t.UnionEnum([...PLATFORMS]),
  apnsEnv: Nullable(t.UnionEnum([...APNS_ENVS])),
  hasApnsToken: t.Boolean(),
  hasPushToStartToken: t.Boolean(),
  registeredAt: t.String(),
});

export const ActivityTokenBody = t.Object({
  token: t.String({ pattern: "^[0-9a-fA-F]+$", maxLength: 1024 }),
});

// ── Stats ────────────────────────────────────────────────────────────────────

/** `days` is an integer 1..365 (default 30 when absent); anything else is a 400 `bad_request`. Elysia coerces the query text. */
export const StatsQuery = t.Object({
  days: t.Optional(t.Number({ multipleOf: 1, minimum: 1, maximum: 365 })),
});
export const StatsResponse = t.Object({
  days: Int,
  /** First and last local day of the window (server time zone), `YYYY-MM-DD`, inclusive. */
  from: t.String(),
  to: t.String(),
  // `kind` is null for a memo with none: mode `transcribe`, a failed memo, an old one.
  perDay: t.Array(t.Object({ date: t.String(), kind: Nullable(t.String()), count: Int })),
  perWeek: t.Array(t.Object({ weekStart: t.String(), count: Int })),
  stepMedians: t.Array(
    t.Object({ step: Step, kind: Nullable(t.String()), medianMs: Int, samples: Int }),
  ),
  costPerKind: t.Array(t.Object({ kind: Nullable(t.String()), costUsd: t.Number(), memos: Int })),
});

// ── Service ──────────────────────────────────────────────────────────────────

export const HealthResponse = t.Object({
  status: t.UnionEnum(["ok", "degraded"]),
  degraded: t.Array(t.String()),
  inflight: Int,
});

export const WhoamiResponse = t.Object({ device: t.String() });

// ── Telemetry ────────────────────────────────────────────────────────────────

const TraceId = t.String({ pattern: "^[0-9a-f]{32}$" });
const SpanId = t.String({ pattern: "^[0-9a-f]{16}$" });
/** ISO 8601 UTC, `2026-10-27T12:00:00.250Z`; the clients send milliseconds, up to nanoseconds is read. */
const Timestamp = t.String({
  pattern: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d{1,9})?Z$",
});
const TelemetryAttributes = t.Record(t.String(), t.Union([t.String(), t.Number(), t.Boolean()]));

export const TelemetryResource = t.Object({
  serviceName: t.UnionEnum(["iris-ios", "iris-macos"]),
  deviceName: t.String({ minLength: 1 }),
  appVersion: t.String({ minLength: 1 }),
});

export const TelemetrySpan = t.Object({
  traceId: TraceId,
  spanId: SpanId,
  parentSpanId: t.Optional(SpanId),
  name: t.String({ minLength: 1 }),
  startTime: Timestamp,
  endTime: Timestamp,
  status: t.UnionEnum(["unset", "ok", "error"]),
  attributes: TelemetryAttributes,
});

export const TelemetryLog = t.Object({
  timestamp: Timestamp,
  severity: t.UnionEnum(["info", "warn", "error"]),
  body: t.String(),
  traceId: t.Optional(TraceId),
  attributes: TelemetryAttributes,
});

/**
 * The client span/log relay (TDD §8). `traceId` is the memo UUID without dashes where the record belongs to a
 * memo. `dropped` counts the records the client discarded on buffer overflow since its previous batch. Delivery is
 * at-least-once and the server does not de-duplicate (`(traceId, spanId)` identifies a span).
 */
export const TelemetryBatch = t.Object({
  resource: TelemetryResource,
  spans: t.Array(TelemetrySpan, { maxItems: TELEMETRY_MAX_RECORDS }),
  logs: t.Array(TelemetryLog, { maxItems: TELEMETRY_MAX_RECORDS }),
  dropped: t.Number({ multipleOf: 1, minimum: 0 }),
});

export const TelemetryResponse = t.Object({
  accepted: t.Object({ spans: Int, logs: Int }),
});
