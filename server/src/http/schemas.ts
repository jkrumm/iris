import { t } from "elysia";
import { MEMO_ERROR_CODES } from "../memo/errors.js";
import { MEMO_MODES, MEMO_STATES, STEPS, THREAD_KINDS } from "../memo/memo.js";
import { APNS_ENVS, PLATFORMS } from "../ports/devices.js";
import { DESTINATION_NAMES } from "../ports/destination.js";
import { AGENT_STATES } from "../ports/herd.js";
import { TELEMETRY_MAX_RECORDS } from "../telemetry/limits.js";

// Every request and response shape on the wire, in one file. Pure TypeBox (no Transform or custom
// codec) so they export to JSON Schema as they are. Response schemas mirror what `serialize.ts`
// emits field for field; the serializers stay the single mapping from domain to wire.
// Two deliberate exceptions to "pure": `ListQuery.limit` and `ResultQuery.wait` use `t.Numeric`
// because query strings arrive as text. `GET /events` (SSE) and the binary routes
// (`/memos/:id/audio`, `/memos/:id/speech`) have no JSON success body; the guard's 401 is the
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
  route: Nullable(t.String()),
  destinationRef: Nullable(t.String()),
  replyText: Nullable(t.String()),
  summary: Nullable(Summary),
  // Present once the memo belongs to a Hermes session (chat or not): set when `act` ran in it, or at creation for a memo that
  // continues a thread; omitted, never null, otherwise.
  threadId: t.Optional(t.String()),
  // Present (and `true`) only for a typed memo, one created from text; omitted for a recording.
  typed: t.Optional(t.Literal(true)),
  // Present only while the memo is `needs_route`: why it parked, and the model's guess on a low-confidence park.
  routeReason: t.Optional(t.String()),
  routeSuggestion: t.Optional(t.String()),
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
});

/** The memo plus its step timeline; `segmentCount` is never null here. */
export const MemoDetail = t.Object({
  ...memoFields,
  segmentCount: Int,
  steps: t.Array(StepRecord),
});

// ── Threads ──────────────────────────────────────────────────────────────────

const ThreadKind = t.UnionEnum([...THREAD_KINDS]);

/** A Hermes session that memos ran in; `kind` `chat` marks a side-effect-free conversation. */
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

export const MemoList = t.Object({ items: t.Array(Memo), nextCursor: Nullable(t.String()) });

export const MemoIdParams = t.Object({ id: t.String() });
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
export const RetryBody = t.Object({ from: t.UnionEnum([...STEPS], { default: undefined }) });
/** `tab` is required for `herdr` and rejected for the others (400 `bad_request`). */
export const RouteBody = t.Object({
  // `UnionEnum` defaults a missing value to its first member; a missing destination must be a 400, not "hermes".
  destination: t.UnionEnum([...DESTINATION_NAMES], { default: undefined }),
  tab: t.Optional(t.String({ minLength: 1 })),
});

export const ListQuery = t.Object({
  limit: t.Optional(t.Numeric()),
  cursor: t.Optional(t.String()),
});
export const ThreadIdParams = t.Object({ id: t.String() });
// `default: undefined`: a missing `kind` must stay missing, not become the first member.
export const ThreadListQuery = t.Object({
  kind: t.Optional(t.UnionEnum([...THREAD_KINDS], { default: undefined })),
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

// ── Herd ─────────────────────────────────────────────────────────────────────

export const HerdTab = t.Object({
  id: t.String(),
  repo: t.String(),
  label: t.String(),
  agentState: t.UnionEnum([...AGENT_STATES]),
  lastActivity: Nullable(t.String()),
});
export const HerdResponse = t.Object({ tabs: t.Array(HerdTab) });

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
  perDay: t.Array(t.Object({ date: t.String(), route: t.String(), count: Int })),
  perWeek: t.Array(t.Object({ weekStart: t.String(), count: Int })),
  stepMedians: t.Array(t.Object({ step: Step, route: t.String(), medianMs: Int, samples: Int })),
  costPerRoute: t.Array(t.Object({ route: t.String(), costUsd: t.Number(), memos: Int })),
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
