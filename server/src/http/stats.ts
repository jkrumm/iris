import { Elysia } from "elysia";
import { configured, MemoError } from "../memo/errors.js";
import type { StatsStore } from "../ports/stats.js";
import type { deviceAuth } from "./auth.js";
import { ErrorBody, StatsQuery, StatsResponse } from "./schemas.js";

const DEFAULT_DAYS = 30;
const MAX_DAYS = 365;

/** `GET /stats?days=<n>`: memo volume, step durations and cost over the last `n` local days (default 30, 1..365). */
export function statsRoutes(deps: {
  stats: StatsStore | undefined;
  auth: ReturnType<typeof deviceAuth>;
}) {
  const { stats, auth } = deps;

  return new Elysia().use(auth).get(
    "/stats",
    ({ query }) => {
      const days = query.days ?? DEFAULT_DAYS;
      if (!Number.isInteger(days) || days < 1 || days > MAX_DAYS) {
        throw new MemoError("bad_request", `days must be an integer from 1 to ${MAX_DAYS}`);
      }
      return configured(stats, "stats").summary({ days });
    },
    { query: StatsQuery, response: { 200: StatsResponse, 400: ErrorBody, 503: ErrorBody } },
  );
}
