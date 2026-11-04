import type { Database } from "bun:sqlite";
import { STEPS, type Step } from "../memo/memo.js";
import type { Clock } from "../ports/clock.js";
import type { Stats, StatsStore } from "../ports/stats.js";
import { migrate } from "./sqlite.js";

const pad = (n: number) => String(n).padStart(2, "0");
const localDay = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;

/** Local midnight of the Monday on or before `d`. */
const mondayOf = (d: Date) =>
  new Date(d.getFullYear(), d.getMonth(), d.getDate() - ((d.getDay() + 6) % 7));

/** Middle value of `sorted`; the mean of the two middle values (rounded) when the count is even. */
export function median(sorted: number[]): number {
  const mid = sorted.length >> 1;
  if (sorted.length % 2 === 1) return sorted[mid] as number;
  return Math.round(((sorted[mid - 1] as number) + (sorted[mid] as number)) / 2);
}

/** Kinds alphabetically, the memos with none (`null`) first. */
const compareKinds = (x: string | null, y: string | null) => (x ?? "").localeCompare(y ?? "");

/** Stats over the same database as the memo store. Days are the server's local days (the process time zone). */
export function createSqliteStatsStore(params: { db: Database; clock: Clock }): StatsStore {
  const { db, clock } = params;
  migrate(db);

  return {
    summary({ days }): Stats {
      const now = clock.now();
      const start = new Date(now.getFullYear(), now.getMonth(), now.getDate() - (days - 1));
      const since = start.toISOString();

      // Bucketed here, not with SQLite's `localtime`: the window and the days must share one time zone source (JS `TZ`).
      const dayCounts = new Map<string, { date: string; kind: string | null; count: number }>();
      const weekCounts = new Map<string, number>();
      const memoRows = db
        .query<{ created_at: string; kind: string | null }, [string]>(
          "SELECT created_at, kind FROM memos WHERE created_at >= ?",
        )
        .all(since);
      for (const row of memoRows) {
        const created = new Date(row.created_at);
        const date = localDay(created);
        const key = JSON.stringify([date, row.kind]);
        const bucket = dayCounts.get(key) ?? { date, kind: row.kind, count: 0 };
        bucket.count++;
        dayCounts.set(key, bucket);
        const week = localDay(mondayOf(created));
        weekCounts.set(week, (weekCounts.get(week) ?? 0) + 1);
      }
      const perDay = [...dayCounts.values()].sort(
        (x, y) => x.date.localeCompare(y.date) || compareKinds(x.kind, y.kind),
      );
      const perWeek = [...weekCounts]
        .map(([weekStart, count]) => ({ weekStart, count }))
        .sort((x, y) => x.weekStart.localeCompare(y.weekStart));

      // Keyed by step and the memo's kind: how long `act` takes depends on what Hermes made of the memo. Steps of memos from
      // before Hermes decided (`route`) are in too, under their old memos' kind (none).
      const durations = new Map<string, { step: Step; kind: string | null; ms: number[] }>();
      const stepRows = db
        .query<
          { step: Step; kind: string | null; started_at: string; finished_at: string },
          [string]
        >(
          `SELECT s.step, m.kind, s.started_at, s.finished_at
           FROM memo_steps s JOIN memos m ON m.id = s.memo_id
           WHERE s.status = 'done' AND s.finished_at IS NOT NULL AND s.started_at >= ?`,
        )
        .all(since);
      for (const row of stepRows) {
        const ms = Math.max(0, Date.parse(row.finished_at) - Date.parse(row.started_at));
        const key = JSON.stringify([row.step, row.kind]);
        const group = durations.get(key) ?? { step: row.step, kind: row.kind, ms: [] };
        group.ms.push(ms);
        durations.set(key, group);
      }
      const stepMedians = [...durations.values()]
        .sort(
          (x, y) => STEPS.indexOf(x.step) - STEPS.indexOf(y.step) || compareKinds(x.kind, y.kind),
        )
        .map(({ step, kind, ms }) => ({
          step,
          kind,
          medianMs: median(ms.sort((x, y) => x - y)),
          samples: ms.length,
        }));

      const costPerKind = db
        .query<{ kind: string | null; costUsd: number; memos: number }, [string]>(
          `SELECT m.kind AS kind, COALESCE(SUM(s.cost_usd), 0) AS costUsd, COUNT(DISTINCT m.id) AS memos
           FROM memos m LEFT JOIN memo_steps s ON s.memo_id = m.id
           WHERE m.created_at >= ? GROUP BY m.kind ORDER BY m.kind`,
        )
        .all(since)
        // Summed floats carry binary noise (0.1 + 0.2); micro-dollars are finer than any bill.
        .map((row) => ({ ...row, costUsd: Math.round(row.costUsd * 1e6) / 1e6 }));

      return {
        days,
        from: localDay(start),
        to: localDay(now),
        perDay,
        perWeek,
        stepMedians,
        costPerKind,
      };
    },
  };
}
