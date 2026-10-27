import { Elysia, t } from "elysia";
import { MemoError } from "../memo/errors.js";
import { MEMO_MODES, STEPS } from "../memo/memo.js";
import type { MemoService } from "../memo/service.js";
import type { deviceAuth } from "./auth.js";
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

/** `/memos/*`. Takes the guard instance so handlers see the derived `device`. */
export function memoRoutes(deps: { memos: MemoService; auth: ReturnType<typeof deviceAuth> }) {
  const { memos, auth } = deps;
  const id = t.Object({ id: t.String() });

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
        });
        set.status = created ? 201 : 200;
        return memoJson(memo);
      },
      {
        body: t.Object({
          id: t.String(),
          mode: t.UnionEnum([...MEMO_MODES]),
          startedAt: t.String(),
        }),
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
        params: t.Object({ id: t.String(), n: t.String({ pattern: "^[0-9]{1,7}$" }) }),
      },
    )
    .post(
      "/:id/complete",
      ({ params, body, set }) => {
        const memo = memos.complete({ id: params.id, segmentCount: body.segmentCount });
        set.status = 202;
        return memoJson(memo);
      },
      { params: id, body: t.Object({ segmentCount: t.Integer() }) },
    )
    .post(
      "/:id/retry",
      ({ params, body, set }) => {
        const memo = memos.retry({ id: params.id, from: body.from });
        set.status = 202;
        return memoJson(memo);
      },
      { params: id, body: t.Object({ from: t.UnionEnum([...STEPS]) }) },
    )
    .get(
      "/",
      ({ query }) => {
        const { memos: items, nextCursor } = memos.list({
          ...(query.limit !== undefined && { limit: query.limit }),
          cursor: query.cursor,
        });
        return { items: items.map(memoJson), nextCursor };
      },
      { query: t.Object({ limit: t.Optional(t.Numeric()), cursor: t.Optional(t.String()) }) },
    )
    .get("/:id", ({ params }) => detailJson(memos.get(params.id)), { params: id })
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
      { params: id, query: t.Object({ wait: t.Optional(t.Numeric()) }) },
    );
}
