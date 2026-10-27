import { Elysia } from "elysia";
import type { MemoService } from "../memo/service.js";
import type { deviceAuth } from "./auth.js";
import { ErrorBody, ThreadDetail, ThreadIdParams, ThreadList, ThreadListQuery } from "./schemas.js";
import { threadDetailJson, threadJson } from "./serialize.js";

/** `/threads/*`: Iris's own record of a conversation; Hermes is not consulted. */
export function threadRoutes(deps: { memos: MemoService; auth: ReturnType<typeof deviceAuth> }) {
  const { memos, auth } = deps;

  return new Elysia({ prefix: "/threads" })
    .use(auth)
    .get(
      "/",
      ({ query }) => {
        const { threads, nextCursor } = memos.listThreads({
          kind: query.kind,
          ...(query.limit !== undefined && { limit: query.limit }),
          cursor: query.cursor,
        });
        return { items: threads.map(threadJson), nextCursor };
      },
      { query: ThreadListQuery, response: { 200: ThreadList, 400: ErrorBody } },
    )
    .get("/:id", ({ params }) => threadDetailJson(memos.getThread(params.id)), {
      params: ThreadIdParams,
      response: { 200: ThreadDetail, 404: ErrorBody },
    });
}
