import { Elysia } from "elysia";
import { configured } from "../memo/errors.js";
import type { StatsStore } from "../ports/stats.js";
import type { deviceAuth } from "./auth.js";
import { ErrorBody, StatsQuery, StatsResponse } from "./schemas.js";

const DEFAULT_DAYS = 30;

/** `GET /stats?days=<n>`: memo volume, step durations and cost over the last `n` local days (`StatsQuery` bounds `n`, default 30). */
export function statsRoutes(deps: {
  stats: StatsStore | undefined;
  auth: ReturnType<typeof deviceAuth>;
}) {
  const { stats, auth } = deps;

  return new Elysia().use(auth).get(
    "/stats",
    ({ query }) => {
      return configured(stats, "stats").summary({ days: query.days ?? DEFAULT_DAYS });
    },
    { query: StatsQuery, response: { 200: StatsResponse, 400: ErrorBody, 503: ErrorBody } },
  );
}
