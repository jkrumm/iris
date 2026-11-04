import type { Step } from "../memo/memo.js";

export interface Stats {
  days: number;
  /** First and last local day of the window, `YYYY-MM-DD`, inclusive. */
  from: string;
  to: string;
  /** `kind` is null for a memo with none: mode `transcribe`, a failed memo, an old one. */
  perDay: { date: string; kind: string | null; count: number }[];
  /** Weeks start on Monday; the first week of the window only counts the days inside it. */
  perWeek: { weekStart: string; count: number }[];
  /** Per step and kind; `samples` is the n behind the median, the client decides when it is enough to show. */
  stepMedians: { step: Step; kind: string | null; medianMs: number; samples: number }[];
  costPerKind: { kind: string | null; costUsd: number; memos: number }[];
}

/** A read-only view over the memo tables; it never writes and never spends. */
export interface StatsStore {
  /** Aggregates of the memos created in the last `days` local days, today included. */
  summary(params: { days: number }): Stats;
}
