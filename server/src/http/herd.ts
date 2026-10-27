import { Elysia } from "elysia";
import { configured } from "../memo/errors.js";
import type { Herd } from "../ports/herd.js";
import type { deviceAuth } from "./auth.js";
import { ErrorBody, HerdResponse } from "./schemas.js";

/** `GET /herd`: the live herdr tabs, a snapshot only. 503 when herdr is not configured or unreachable. */
export function herdRoutes(deps: { herd: Herd | undefined; auth: ReturnType<typeof deviceAuth> }) {
  const { herd, auth } = deps;

  return new Elysia()
    .use(auth)
    .get("/herd", async () => ({ tabs: await configured(herd, "herd").snapshot() }), {
      response: { 200: HerdResponse, 503: ErrorBody },
    });
}
