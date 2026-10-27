import { Elysia } from "elysia";
import type { MemoMedia } from "./memo/media.js";
import type { MemoService } from "./memo/service.js";
import { deviceAuth } from "./http/auth.js";
import { deviceRoutes } from "./http/devices.js";
import { httpErrors } from "./http/errors.js";
import { eventRoutes } from "./http/events.js";
import { herdRoutes } from "./http/herd.js";
import { mediaRoutes } from "./http/media.js";
import { memoRoutes } from "./http/memos.js";
import { threadRoutes } from "./http/threads.js";
import { HealthResponse, WhoamiResponse } from "./http/schemas.js";
import { statsRoutes } from "./http/stats.js";
import { telemetryRoutes } from "./http/telemetry.js";
import type { DeviceStore } from "./ports/devices.js";
import type { Herd } from "./ports/herd.js";
import type { StatsStore } from "./ports/stats.js";
import type { TelemetryRelay } from "./telemetry/relay.js";

export interface AppDeps {
  deviceTokens: Map<string, string>;
  memos: MemoService;
  /** Unset routes answer 503 `unavailable`; their subsystem is then listed in `degraded`. */
  devices?: DeviceStore | undefined;
  media?: MemoMedia | undefined;
  herd?: Herd | undefined;
  telemetry?: TelemetryRelay | undefined;
  stats?: StatsStore | undefined;
  /** Names of optional subsystems that are not configured; surfaced on /health. */
  degraded?: string[];
  /** Memos with a step running right now; surfaced on /health so the deploy poller can wait for idle. */
  inflight?: () => number;
  /** SSE keepalive comment interval; tests shrink it. */
  sseKeepaliveMs?: number | undefined;
}

/** Composition root: wires adapters into ports and mounts routes. Nothing else. */
export function createApp(deps: AppDeps) {
  const degraded = deps.degraded ?? [];
  const auth = deviceAuth(deps.deviceTokens);
  const { memos, stats, devices, media, herd, telemetry } = deps;
  return new Elysia()
    .use(httpErrors)
    .get(
      "/health",
      () => ({
        status: degraded.length > 0 ? ("degraded" as const) : ("ok" as const),
        degraded,
        inflight: deps.inflight?.() ?? 0,
      }),
      { response: HealthResponse },
    )
    .group("/v1", (v1) =>
      v1
        .use(auth)
        .get("/whoami", ({ device }) => ({ device: device as string }), {
          response: WhoamiResponse,
        })
        .use(memoRoutes({ memos, auth }))
        .use(threadRoutes({ memos, auth }))
        .use(deviceRoutes({ devices, memos, auth }))
        .use(telemetryRoutes({ telemetry, auth }))
        .use(mediaRoutes({ media, auth }))
        .use(herdRoutes({ herd, auth }))
        .use(statsRoutes({ stats, auth }))
        .use(eventRoutes({ memos, auth, keepaliveMs: deps.sseKeepaliveMs })),
    );
}
