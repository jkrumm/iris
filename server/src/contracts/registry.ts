import { t, type TSchema } from "elysia";
import { z } from "zod";
import { ShowSpec } from "../memo/reply-artifacts.js";
import {
  ActivityTokenBody,
  CompleteBody,
  CreateMemoBody,
  CreateTextMemoBody,
  Device,
  ErrorBody,
  FlagsBody,
  HealthResponse,
  ListQuery,
  Memo,
  MemoDetail,
  MemoActivityPayload,
  MemoDeltaPayload,
  MemoEventPayload,
  MemoList,
  MissingSegmentsError,
  RegisterDeviceBody,
  ResultQuery,
  RetryBody,
  StatsQuery,
  StatsResponse,
  TelemetryBatch,
  TelemetryResponse,
  ThreadDetail,
  ThreadList,
  ThreadListQuery,
  TooLargeError,
  WhoamiResponse,
} from "../http/schemas.js";
import { AlertPayload, ContentState } from "../notify/payloads.js";

/**
 * Every JSON contract, by name (`<resource>.<operation>.<request|response|query>`). The name is the
 * file stem in `contracts/schema/` and the prefix of its fixtures in `contracts/fixtures/`.
 * `contracts/manifest.json` maps routes onto these names; a schema nothing references fails the check.
 */
export const CONTRACT_SCHEMAS: Record<string, TSchema> = {
  "memos.create.request": CreateMemoBody,
  "memos.create.response": Memo,
  "memos.text.request": CreateTextMemoBody,
  "memos.text.response": Memo,
  "memos.complete.request": CompleteBody,
  "memos.complete.response": Memo,
  "memos.retry.request": RetryBody,
  "memos.retry.response": Memo,
  "memos.list.query": ListQuery,
  "memos.list.response": MemoList,
  "memos.detail.response": MemoDetail,
  "memos.result.query": ResultQuery,
  "memos.result.response": Memo,
  "memos.flags.request": FlagsBody,
  "memos.flags.response": Memo,
  "memos.delete.response": Memo,
  "memos.restore.response": Memo,
  "memos.activity-token.request": ActivityTokenBody,
  "threads.list.query": ThreadListQuery,
  "threads.list.response": ThreadList,
  "threads.detail.response": ThreadDetail,
  "devices.register.request": RegisterDeviceBody,
  "devices.register.response": Device,
  "telemetry.request": TelemetryBatch,
  "telemetry.response": TelemetryResponse,
  "stats.query": StatsQuery,
  "stats.response": StatsResponse,
  "health.response": HealthResponse,
  "whoami.response": WhoamiResponse,
  error: ErrorBody,
  "error.missing-segments": MissingSegmentsError,
  "error.too-large": TooLargeError,
  // SSE `data:` payloads. `ready` carries an empty object.
  "events.ready": t.Object({}, { maxProperties: 0 }),
  "events.memo-updated": MemoEventPayload,
  "events.memo-done": MemoEventPayload,
  "events.memo-delta": MemoDeltaPayload,
  "events.memo-activity": MemoActivityPayload,
  // Push payloads the server sends to APNs and the apps decode.
  "liveactivity.content-state": ContentState,
  "push.alert": AlertPayload,
};

/**
 * Contracts that are not a route's TypeBox body, already plain JSON Schema (zod 4's `z.toJSONSchema`), by the same kind of
 * name. Unknown keys stay rejected (`additionalProperties: false`): a spec is a contract the clients render, not a body they skip.
 */
export const JSON_SCHEMA_CONTRACTS: Record<string, object> = {
  "artifacts.show-spec": z.toJSONSchema(ShowSpec, { target: "draft-2020-12", io: "input" }),
};
