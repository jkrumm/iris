import { Database } from "bun:sqlite";
import { describe, expect, it } from "bun:test";
import { join } from "node:path";
import { fixedClock } from "../ports/clock.js";
import { createSqliteStatsStore, median } from "./sqlite-stats.js";

// Wednesday 2026-10-28, local time of the machine running the tests (the adapter groups by local day).
const NOW = new Date(2026, 9, 28, 12, 0, 0);
const at = (month: number, day: number, hour = 12, minute = 0, second = 0, ms = 0) =>
  new Date(2026, month - 1, day, hour, minute, second, ms).toISOString();

function seeded(now: Date = NOW) {
  const db = new Database(":memory:");
  const stats = createSqliteStatsStore({ db, clock: fixedClock(now) });
  let seq = 0;
  return {
    stats,
    memo(input: { createdAt: string; kind?: string | null }) {
      const id = `memo-${++seq}`;
      db.query(
        `INSERT INTO memos (id, mode, device, started_at, state, created_at, updated_at, kind)
         VALUES (?, 'auto', 'iphone', ?, 'notified', ?, ?, ?)`,
      ).run(id, input.createdAt, input.createdAt, input.createdAt, input.kind ?? null);
      return id;
    },
    step(input: {
      memoId: string;
      step: string;
      startedAt: string;
      durationMs?: number;
      status?: string;
      costUsd?: number;
    }) {
      const finished =
        input.durationMs === undefined
          ? null
          : new Date(Date.parse(input.startedAt) + input.durationMs).toISOString();
      db.query(
        `INSERT INTO memo_steps (memo_id, step, status, started_at, finished_at, cost_usd)
         VALUES (?, ?, ?, ?, ?, ?)`,
      ).run(
        input.memoId,
        input.step,
        input.status ?? "done",
        input.startedAt,
        finished,
        input.costUsd ?? null,
      );
    },
  };
}

type PerDay = { date: string; kind: string | null; count: number };

describe("the stats.response fixture", () => {
  it("is what the server produces from its own perDay: days and weeks", async () => {
    const fixture = await Bun.file(
      join(import.meta.dir, "../../../contracts/fixtures/stats.response.json"),
    ).json();
    const [year = 0, month = 0, day = 0] = fixture.to.split("-").map(Number);
    const { stats, memo } = seeded(new Date(year, month - 1, day, 12));
    for (const { date, kind, count } of fixture.perDay) {
      const [y = 0, m = 0, d = 0] = date.split("-").map(Number);
      for (let i = 0; i < count; i++) {
        memo({ createdAt: new Date(y, m - 1, d, 12).toISOString(), kind });
      }
    }
    expect(stats.summary({ days: fixture.days })).toMatchObject({
      from: fixture.from,
      to: fixture.to,
      perDay: fixture.perDay.toSorted(
        (x: PerDay, y: PerDay) =>
          x.date.localeCompare(y.date) || (x.kind ?? "").localeCompare(y.kind ?? ""),
      ),
      perWeek: fixture.perWeek,
    });
  });
});

describe("median", () => {
  it("takes the middle of an odd count", () => expect(median([1, 5, 9])).toBe(5));
  it("averages the middle two of an even count, rounded", () => {
    expect(median([2, 4])).toBe(3);
    expect(median([1, 2])).toBe(2);
  });
  it("is the value itself for one sample", () => expect(median([7])).toBe(7));
});

describe("sqlite stats", () => {
  it("answers an empty window with empty lists and the window bounds", () => {
    const { stats, memo } = seeded();
    memo({ createdAt: at(8, 1), kind: "task" }); // far outside a 7-day window
    expect(stats.summary({ days: 7 })).toEqual({
      days: 7,
      from: "2026-10-22",
      to: "2026-10-28",
      perDay: [],
      perWeek: [],
      stepMedians: [],
      costPerKind: [],
    });
  });

  it("windows by local day: days=1 is today only, midnight inclusive", () => {
    const { stats, memo } = seeded();
    memo({ createdAt: at(10, 27, 23, 59, 59, 999), kind: "task" });
    memo({ createdAt: at(10, 28, 0, 0, 0, 0), kind: "task" });
    memo({ createdAt: at(10, 28, 9), kind: "note" });
    const today = stats.summary({ days: 1 });
    expect([today.from, today.to]).toEqual(["2026-10-28", "2026-10-28"]);
    expect(today.perDay).toEqual([
      { date: "2026-10-28", kind: "note", count: 1 },
      { date: "2026-10-28", kind: "task", count: 1 },
    ]);
    expect(stats.summary({ days: 2 }).perDay.map((d) => d.date)).toEqual([
      "2026-10-27",
      "2026-10-28",
      "2026-10-28",
    ]);
  });

  it("counts per local day and kind, keeping memos without a kind (null first)", () => {
    const { stats, memo } = seeded();
    memo({ createdAt: at(10, 26, 8), kind: "task" });
    memo({ createdAt: at(10, 26, 20), kind: "task" });
    memo({ createdAt: at(10, 26, 21), kind: null });
    memo({ createdAt: at(10, 28, 7), kind: "idea" });
    expect(stats.summary({ days: 30 }).perDay).toEqual([
      { date: "2026-10-26", kind: null, count: 1 },
      { date: "2026-10-26", kind: "task", count: 2 },
      { date: "2026-10-28", kind: "idea", count: 1 },
    ]);
  });

  it("totals per Monday-start week; Sunday belongs to the week before", () => {
    const { stats, memo } = seeded();
    memo({ createdAt: at(10, 18, 10) }); // Sunday  -> week of 10-12
    memo({ createdAt: at(10, 19, 10) }); // Monday  -> week of 10-19
    memo({ createdAt: at(10, 25, 10) }); // Sunday  -> week of 10-19
    memo({ createdAt: at(10, 26, 10) }); // Monday  -> week of 10-26
    memo({ createdAt: at(10, 28, 10) });
    expect(stats.summary({ days: 30 }).perWeek).toEqual([
      { weekStart: "2026-10-12", count: 1 },
      { weekStart: "2026-10-19", count: 2 },
      { weekStart: "2026-10-26", count: 2 },
    ]);
  });

  it("computes step medians per step and kind in pipeline order (odd, even, single)", () => {
    const { stats, memo, step } = seeded();
    const a = memo({ createdAt: at(10, 27), kind: "task" });
    const b = memo({ createdAt: at(10, 27), kind: "task" });
    const c = memo({ createdAt: at(10, 27), kind: "task" });
    const d = memo({ createdAt: at(10, 27), kind: "task" });
    const j = memo({ createdAt: at(10, 27), kind: "note" });
    const parked = memo({ createdAt: at(10, 27), kind: null });
    // transcribe, task: 1000, 5000, 3000 -> odd, median 3000
    for (const [id, ms] of [
      [a, 1000],
      [b, 5000],
      [c, 3000],
    ] as const) {
      step({ memoId: id, step: "transcribe", startedAt: at(10, 27, 12), durationMs: ms });
    }
    // act, task: 100, 201, 300, 700 -> even, mean of 201 and 300 = 250.5 -> 251
    for (const [id, ms] of [
      [a, 100],
      [b, 700],
      [c, 201],
      [d, 300],
    ] as const) {
      step({ memoId: id, step: "act", startedAt: at(10, 27, 12), durationMs: ms });
    }
    // the same step on another kind is its own baseline; a memo without a kind (transcribe mode, or none set) reports null
    step({ memoId: j, step: "transcribe", startedAt: at(10, 27, 12), durationMs: 800 });
    step({ memoId: j, step: "act", startedAt: at(10, 27, 12), durationMs: 12 });
    step({ memoId: parked, step: "act", startedAt: at(10, 27, 12), durationMs: 77 });
    step({ memoId: parked, step: "transcribe", startedAt: at(10, 27, 12), durationMs: 400 });
    // not counted: failed, still running, and a done step that started before the window
    step({
      memoId: b,
      step: "notify",
      startedAt: at(10, 27, 12),
      durationMs: 9999,
      status: "failed",
    });
    step({ memoId: c, step: "notify", startedAt: at(10, 27, 12), status: "running" });
    step({ memoId: d, step: "notify", startedAt: at(9, 1), durationMs: 5 });
    expect(stats.summary({ days: 7 }).stepMedians).toEqual([
      { step: "transcribe", kind: null, medianMs: 400, samples: 1 },
      { step: "transcribe", kind: "note", medianMs: 800, samples: 1 },
      { step: "transcribe", kind: "task", medianMs: 3000, samples: 3 },
      { step: "act", kind: null, medianMs: 77, samples: 1 },
      { step: "act", kind: "note", medianMs: 12, samples: 1 },
      { step: "act", kind: "task", medianMs: 251, samples: 4 },
    ]);
  });

  it("sums step cost per kind, with memos counted once and memos without a kind kept (null first)", () => {
    const { stats, memo, step } = seeded();
    const h1 = memo({ createdAt: at(10, 27), kind: "task" });
    const h2 = memo({ createdAt: at(10, 28), kind: "task" });
    memo({ createdAt: at(10, 28), kind: "note" });
    const parked = memo({ createdAt: at(10, 28), kind: null });
    const old = memo({ createdAt: at(8, 1), kind: "task" });
    step({ memoId: h1, step: "act", startedAt: at(10, 27), durationMs: 1, costUsd: 0.1 });
    step({ memoId: h1, step: "notify", startedAt: at(10, 27), durationMs: 1, costUsd: 0.2 });
    step({ memoId: h2, step: "act", startedAt: at(10, 28), durationMs: 1, costUsd: 0.05 });
    step({ memoId: parked, step: "act", startedAt: at(10, 28), durationMs: 1, costUsd: 0.01 });
    step({ memoId: old, step: "act", startedAt: at(8, 1), durationMs: 1, costUsd: 5 });
    expect(stats.summary({ days: 30 }).costPerKind).toEqual([
      { kind: null, costUsd: 0.01, memos: 1 },
      { kind: "note", costUsd: 0, memos: 1 },
      { kind: "task", costUsd: 0.35, memos: 2 },
    ]);
  });
});
