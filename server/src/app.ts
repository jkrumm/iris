import { Elysia } from "elysia";
import type { MemoService } from "./memo/service.js";
import { deviceAuth } from "./http/auth.js";
import { httpErrors } from "./http/errors.js";
import { eventRoutes } from "./http/events.js";
import { memoRoutes } from "./http/memos.js";

export interface AppDeps {
  deviceTokens: Map<string, string>;
  memos: MemoService;
  /** Names of optional subsystems that are not configured; surfaced on /health. */
  degraded?: string[];
  /** SSE keepalive comment interval; tests shrink it. */
  sseKeepaliveMs?: number | undefined;
}

/** Composition root: wires adapters into ports and mounts routes. Nothing else. */
export function createApp(deps: AppDeps) {
  const degraded = deps.degraded ?? [];
  const auth = deviceAuth(deps.deviceTokens);
  const { memos } = deps;
  return new Elysia()
    .use(httpErrors)
    .get("/health", () => ({
      status: degraded.length > 0 ? ("degraded" as const) : ("ok" as const),
      degraded,
    }))
    .group("/v1", (v1) =>
      v1
        .use(auth)
        .get("/whoami", ({ device }) => ({ device }))
        .use(memoRoutes({ memos, auth }))
        .use(eventRoutes({ memos, auth, keepaliveMs: deps.sseKeepaliveMs })),
    );
}
