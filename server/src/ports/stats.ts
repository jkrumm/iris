import type { Step } from "../memo/memo.js";

/** The `route` a memo reports before it has one (not yet routed, or failed early). */
export const UNROUTED = "unrouted";

export interface Stats {
  days: number;
  /** First and last local day of the window, `YYYY-MM-DD`, inclusive. */
  from: string;
  to: string;
  perDay: { date: string; route: string; count: number }[];
  /** Weeks start on Monday; the first week of the window only counts the days inside it. */
  perWeek: { weekStart: string; count: number }[];
  stepMedians: { step: Step; medianMs: number; samples: number }[];
  costPerRoute: { route: string; costUsd: number; memos: number }[];
}

/** A read-only view over the memo tables; it never writes and never spends. */
export interface StatsStore {
  /** Aggregates of the memos created in the last `days` local days, today included. */
  summary(params: { days: number }): Stats;
}
