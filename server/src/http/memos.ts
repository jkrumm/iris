import { Elysia } from "elysia";
import { MemoError } from "../memo/errors.js";
import type { MemoService } from "../memo/service.js";
import type { deviceAuth } from "./auth.js";
import {
  CompleteBody,
  CreateMemoBody,
  CreateTextMemoBody,
  ErrorBody,
  FlagsBody,
  ListQuery,
  MemoDetail,
  MemoIdParams,
  MemoList,
  Memo,
  MissingSegmentsError,
  ResultQuery,
  RetryBody,
  RouteBody,
  SegmentParams,
  TooLargeError,
} from "./schemas.js";
import { detailJson, memoJson } from "./serialize.js";

const DEFAULT_WAIT_SECONDS = 0;
const MAX_WAIT_SECONDS = 600;
const SEGMENT_TYPES = new Set(["audio/mp4", "application/octet-stream"]);

/**
 * Reads the request body into one buffer, giving up the moment it exceeds `max` bytes. The
 * Content-Length header is only a shortcut: a client can lie, so the byte count is the guard.
 */
async function readBounded(request: Request, max: number): Promise<Uint8Array> {
  const tooLarge = () =>
    new MemoError("too_large", `segment exceeds ${max} bytes`, { maxBytes: max });
  const declared = Number(request.headers.get("content-length"));
  if (declared > max) throw tooLarge();

  const reader = request.body?.getReader();
  if (!reader) return new Uint8Array();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (let part = await reader.read(); !part.done; part = await reader.read()) {
    total += part.value.byteLength;
    if (total > max) {
      await reader.cancel();
      throw tooLarge();
    }
    chunks.push(part.value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

const clampWait = (wait: number | undefined) =>
  Math.min(Math.max(wait ?? DEFAULT_WAIT_SECONDS, 0), MAX_WAIT_SECONDS);

/**
 * Parses a JSON body and refuses keys outside `allowed` (400). Elysia drops unknown body keys before it validates, so
 * a typo like `{"dnoe": true}` would pass as an empty change; this runs first and sees the raw object.
 */
const strictJson =
  (allowed: readonly string[]) =>
  async ({ request }: { request: Request }): Promise<unknown> => {
    const body: unknown = await request.json().catch(() => {
      throw new MemoError("bad_request", "body must be JSON");
    });
    if (typeof body === "object" && body !== null && !Array.isArray(body)) {
      const unknown = Object.keys(body).filter((key) => !allowed.includes(key));
      if (unknown.length > 0) {
        throw new MemoError(
          "bad_request",
          `unknown ${unknown.length > 1 ? "keys" : "key"}: ${unknown.join(", ")}`,
        );
      }
    }
    return body;
  };

/** `/memos/*`. Takes the guard instance so handlers see the derived `device`. */
export function memoRoutes(deps: { memos: MemoService; auth: ReturnType<typeof deviceAuth> }) {
  const { memos, auth } = deps;

  return new Elysia({ prefix: "/memos" })
    .use(auth)
    .post(
      "/",
      ({ body, device, set }) => {
        const { memo, created } = memos.createMemo({
          id: body.id,
          mode: body.mode,
          device: device as string,
          startedAt: body.startedAt,
          threadId: body.threadId,
        });
        set.status = created ? 201 : 200;
        return memoJson(memo);
      },
      {
        body: CreateMemoBody,
        response: { 200: Memo, 201: Memo, 400: ErrorBody, 404: ErrorBody, 409: ErrorBody },
      },
    )
    .post(
      "/text",
      ({ body, device, set }) => {
        const { memo } = memos.createTextMemo({
          id: body.id,
          mode: body.mode,
          device: device as string,
          startedAt: body.startedAt,
          text: body.text,
          threadId: body.threadId,
        });
        set.status = 202;
        return memoJson(memo);
      },
      {
        body: CreateTextMemoBody,
        response: { 202: Memo, 400: ErrorBody, 404: ErrorBody, 409: ErrorBody },
      },
    )
    .put(
      "/:id/segments/:n",
      async ({ params, request, set }) => {
        const type = request.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase();
        if (type && !SEGMENT_TYPES.has(type)) {
          throw new MemoError("bad_request", "content-type must be audio/mp4 or octet-stream");
        }
        const bytes = await readBounded(request, memos.maxSegmentBytes);
        await memos.putSegment({ id: params.id, index: Number(params.n), bytes });
        set.status = 200;
      },
      {
        // Raw bytes: no JSON/form parser may touch the body, the handler streams it itself.
        parse: "none",
        params: SegmentParams,
        response: { 400: ErrorBody, 404: ErrorBody, 409: ErrorBody, 413: TooLargeError },
      },
    )
    .post(
      "/:id/complete",
      ({ params, body, set }) => {
        const memo = memos.complete({ id: params.id, segmentCount: body.segmentCount });
        set.status = 202;
        return memoJson(memo);
      },
      {
        params: MemoIdParams,
        body: CompleteBody,
        response: {
          202: Memo,
          400: ErrorBody,
          404: ErrorBody,
          409: ErrorBody,
          422: MissingSegmentsError,
        },
      },
    )
    .post(
      "/:id/retry",
      ({ params, body, set }) => {
        const memo = memos.retry({ id: params.id, from: body.from });
        set.status = 202;
        return memoJson(memo);
      },
      {
        params: MemoIdParams,
        body: RetryBody,
        response: { 202: Memo, 400: ErrorBody, 404: ErrorBody, 409: ErrorBody },
      },
    )
    .post(
      "/:id/route",
      ({ params, body, set }) => {
        const { memo, accepted } = memos.route({
          id: params.id,
          destination: body.destination,
          tab: body.tab,
        });
        set.status = accepted ? 202 : 200;
        return memoJson(memo);
      },
      {
        params: MemoIdParams,
        body: RouteBody,
        response: { 200: Memo, 202: Memo, 400: ErrorBody, 404: ErrorBody, 409: ErrorBody },
      },
    )
    .get(
      "/",
      ({ query }) => {
        const {
          memos: items,
          pinned,
          nextCursor,
        } = memos.list({
          ...(query.limit !== undefined && { limit: query.limit }),
          cursor: query.cursor,
          q: query.q,
          route: query.route,
          state: query.state,
          favorite: query.favorite === "true" ? true : undefined,
          archived: query.archived === "true" ? true : undefined,
          kind: query.kind,
        });
        return { items: items.map(memoJson), pinned: pinned.map(memoJson), nextCursor };
      },
      { query: ListQuery, response: { 200: MemoList, 400: ErrorBody } },
    )
    .get("/:id", ({ params }) => detailJson(memos.get(params.id)), {
      params: MemoIdParams,
      response: { 200: MemoDetail, 404: ErrorBody },
    })
    .patch("/:id", ({ params, body }) => memoJson(memos.setFlags({ id: params.id, ...body })), {
      parse: strictJson(["done", "favorite", "archived"]),
      params: MemoIdParams,
      body: FlagsBody,
      response: { 200: Memo, 400: ErrorBody, 404: ErrorBody, 409: ErrorBody },
    })
    .delete("/:id", ({ params }) => memoJson(memos.delete(params.id)), {
      params: MemoIdParams,
      response: { 200: Memo, 404: ErrorBody, 409: ErrorBody },
    })
    .post("/:id/restore", ({ params }) => memoJson(memos.restore(params.id)), {
      params: MemoIdParams,
      response: { 200: Memo, 404: ErrorBody, 409: ErrorBody },
    })
    .get(
      "/:id/result",
      async ({ params, query, request, server, set }) => {
        // Bun's idle timeout would cut a long poll; the wait timer bounds it instead.
        server?.timeout(request, 0);
        const { memo, ready } = await memos.waitForResult({
          id: params.id,
          waitSeconds: clampWait(query.wait),
          signal: request.signal,
        });
        set.status = ready ? 200 : 202;
        return memoJson(memo);
      },
      {
        params: MemoIdParams,
        query: ResultQuery,
        response: { 200: Memo, 202: Memo, 404: ErrorBody },
      },
    );
}
