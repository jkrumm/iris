import { t } from "elysia";
import { MEMO_ERROR_CODES } from "../memo/errors.js";
import { MEMO_MODES, MEMO_STATES, STEPS } from "../memo/memo.js";
import { APNS_ENVS, PLATFORMS } from "../ports/devices.js";
import { DESTINATION_NAMES } from "../ports/destination.js";
import { AGENT_STATES } from "../ports/herd.js";

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

export const MemoList = t.Object({ items: t.Array(Memo), nextCursor: Nullable(t.String()) });

export const MemoIdParams = t.Object({ id: t.String() });
export const SegmentParams = t.Object({
  id: t.String(),
  n: t.String({ pattern: "^[0-9]{1,7}$" }),
});

export const CreateMemoBody = t.Object({
  id: t.String(),
  mode: t.UnionEnum([...MEMO_MODES]),
  startedAt: t.String(),
});
/** `text` is trimmed server-side; empty after trimming or longer than 20 000 characters is a 400. */
export const CreateTextMemoBody = t.Object({
  id: t.String(),
  mode: t.UnionEnum([...MEMO_MODES]),
  startedAt: t.String(),
  text: t.String(),
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

// ── Service ──────────────────────────────────────────────────────────────────

export const HealthResponse = t.Object({
  status: t.UnionEnum(["ok", "degraded"]),
  degraded: t.Array(t.String()),
  inflight: Int,
});

export const WhoamiResponse = t.Object({ device: t.String() });
