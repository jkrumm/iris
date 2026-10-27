import type { Database } from "bun:sqlite";
import { STEPS, type Step } from "../memo/memo.js";
import type { Clock } from "../ports/clock.js";
import { UNROUTED, type Stats, type StatsStore } from "../ports/stats.js";
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
      const dayCounts = new Map<string, number>();
      const weekCounts = new Map<string, number>();
      const memoRows = db
        .query<{ created_at: string; route: string }, [string]>(
          `SELECT created_at, COALESCE(route, '${UNROUTED}') AS route FROM memos WHERE created_at >= ?`,
        )
        .all(since);
      for (const row of memoRows) {
        const created = new Date(row.created_at);
        const key = `${localDay(created)}\t${row.route}`;
        dayCounts.set(key, (dayCounts.get(key) ?? 0) + 1);
        const week = localDay(mondayOf(created));
        weekCounts.set(week, (weekCounts.get(week) ?? 0) + 1);
      }
      const perDay = [...dayCounts]
        .map(([key, count]) => {
          const [date = "", route = ""] = key.split("\t");
          return { date, route, count };
        })
        .sort((x, y) => x.date.localeCompare(y.date) || x.route.localeCompare(y.route));
      const perWeek = [...weekCounts]
        .map(([weekStart, count]) => ({ weekStart, count }))
        .sort((x, y) => x.weekStart.localeCompare(y.weekStart));

      const durations = new Map<Step, number[]>();
      const stepRows = db
        .query<{ step: Step; started_at: string; finished_at: string }, [string]>(
          `SELECT step, started_at, finished_at FROM memo_steps
           WHERE status = 'done' AND finished_at IS NOT NULL AND started_at >= ?`,
        )
        .all(since);
      for (const row of stepRows) {
        const ms = Math.max(0, Date.parse(row.finished_at) - Date.parse(row.started_at));
        durations.set(row.step, [...(durations.get(row.step) ?? []), ms]);
      }
      const stepMedians = STEPS.flatMap((step) => {
        const samples = (durations.get(step) ?? []).sort((a, b) => a - b);
        return samples.length === 0
          ? []
          : [{ step, medianMs: median(samples), samples: samples.length }];
      });

      const costPerRoute = db
        .query<{ route: string; costUsd: number; memos: number }, [string]>(
          `SELECT COALESCE(m.route, '${UNROUTED}') AS route, COALESCE(SUM(s.cost_usd), 0) AS costUsd,
             COUNT(DISTINCT m.id) AS memos
           FROM memos m LEFT JOIN memo_steps s ON s.memo_id = m.id
           WHERE m.created_at >= ? GROUP BY route ORDER BY route`,
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
        costPerRoute,
      };
    },
  };
}
