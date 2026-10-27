import { Elysia } from "elysia";
import { deviceAuth } from "./http/auth.js";

export interface AppDeps {
  deviceTokens: Map<string, string>;
  /** Names of optional subsystems that are not configured; surfaced on /health. */
  degraded?: string[];
}

/** Composition root: wires adapters into ports and mounts routes. Nothing else. */
export function createApp(deps: AppDeps) {
  const degraded = deps.degraded ?? [];
  return new Elysia()
    .get("/health", () => ({
      status: degraded.length > 0 ? ("degraded" as const) : ("ok" as const),
      degraded,
    }))
    .group("/v1", (v1) =>
      v1.use(deviceAuth(deps.deviceTokens)).get("/whoami", ({ device }) => ({ device })),
    );
}

export type App = ReturnType<typeof createApp>;
