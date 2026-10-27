import { t, type TSchema } from "elysia";
import {
  ActivityTokenBody,
  CompleteBody,
  CreateMemoBody,
  CreateTextMemoBody,
  Device,
  ErrorBody,
  HealthResponse,
  HerdResponse,
  ListQuery,
  Memo,
  MemoDetail,
  MemoEventPayload,
  MemoList,
  MissingSegmentsError,
  RegisterDeviceBody,
  ResultQuery,
  RetryBody,
  RouteBody,
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
  "memos.route.request": RouteBody,
  "memos.route.response": Memo,
  "memos.list.query": ListQuery,
  "memos.list.response": MemoList,
  "memos.detail.response": MemoDetail,
  "memos.result.query": ResultQuery,
  "memos.result.response": Memo,
  "memos.activity-token.request": ActivityTokenBody,
  "threads.list.query": ThreadListQuery,
  "threads.list.response": ThreadList,
  "threads.detail.response": ThreadDetail,
  "devices.register.request": RegisterDeviceBody,
  "devices.register.response": Device,
  "telemetry.request": TelemetryBatch,
  "telemetry.response": TelemetryResponse,
  "herd.response": HerdResponse,
  "health.response": HealthResponse,
  "whoami.response": WhoamiResponse,
  error: ErrorBody,
  "error.missing-segments": MissingSegmentsError,
  "error.too-large": TooLargeError,
  // SSE `data:` payloads. `ready` carries an empty object.
  "events.ready": t.Object({}, { maxProperties: 0 }),
  "events.memo-updated": MemoEventPayload,
  "events.memo-done": MemoEventPayload,
  // Push payloads the server sends to APNs and the apps decode.
  "liveactivity.content-state": ContentState,
  "push.alert": AlertPayload,
};
