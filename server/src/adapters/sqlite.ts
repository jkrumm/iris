import { Database } from "bun:sqlite";
import { z } from "zod";
import { MemoError } from "../memo/errors.js";
import {
  isCorrectable,
  STEPS,
  stateBefore,
  stepsFrom,
  type Memo,
  type MemoColumnPatch,
  type MemoMode,
  type MemoState,
  type RouteDecisionInput,
  type RouteDecisionRecord,
  type RouteOutcome,
  type RouteSource,
  type Step,
  type StepRecord,
  type Summary,
  type ThreadUpsert,
} from "../memo/memo.js";
import type { AnswerDecision, MemoStore } from "../memo/store.js";
import type { Clock } from "../ports/clock.js";
import { log } from "../telemetry/log.js";
import { MIGRATIONS } from "./sqlite-migrations.js";

/** Opens the data file with WAL and foreign keys on. Tests pass `:memory:`. */
export function openDatabase(path: string): Database {
  const db = new Database(path, { create: true });
  if (path !== ":memory:") db.exec("PRAGMA journal_mode = WAL");
  db.exec("PRAGMA foreign_keys = ON");
  return db;
}

/** Applies the migrations beyond `PRAGMA user_version`, each in its own transaction. */
export function migrate(db: Database, migrations: readonly string[] = MIGRATIONS): void {
  const row = db.query<{ user_version: number }, []>("PRAGMA user_version").get();
  const current = row?.user_version ?? 0;
  for (let version = current; version < migrations.length; version++) {
    const sql = migrations[version];
    if (!sql) continue;
    db.transaction(() => {
      db.exec(sql);
      db.exec(`PRAGMA user_version = ${version + 1}`);
    })();
  }
}

interface MemoRow {
  seq: number;
  id: string;
  mode: string;
  device: string;
  started_at: string;
  state: string;
  failed_step: string | null;
  error: string | null;
  segment_count: number | null;
  audio_seconds: number | null;
  transcript: string | null;
  route: string | null;
  destination_ref: string | null;
  reply_text: string | null;
  summary_json: string | null;
  thread_id: string | null;
  created_at: string;
  updated_at: string;
  /** The latest decision's reason and destination, only while the memo is `needs_route`. */
  park_reason: string | null;
  park_destination: string | null;
}

interface StepRow {
  step: string;
  status: string;
  started_at: string;
  finished_at: string | null;
  error: string | null;
  usage_json: string | null;
  cost_usd: number | null;
}

interface RouteDecisionRow {
  id: number;
  memo_id: string;
  created_at: string;
  source: string;
  destination: string | null;
  tab: string | null;
  confidence: number | null;
  model: string | null;
  cost_usd: number | null;
  reason: string | null;
  outcome: string;
}

const SummarySchema = z.object({ headline: z.string(), detail: z.string(), spoken: z.string() });

/** A stored summary that no longer parses is dropped (null) with a warning, never thrown. */
function parseSummary(row: MemoRow): Summary | null {
  if (row.summary_json === null) return null;
  try {
    const parsed = SummarySchema.safeParse(JSON.parse(row.summary_json));
    if (parsed.success) return parsed.data;
    log("memo.summary_invalid", { memo_id: row.id, error: parsed.error.message });
  } catch (err) {
    log("memo.summary_invalid", { memo_id: row.id, error: String(err) });
  }
  return null;
}

const toMemo = (row: MemoRow): Memo => ({
  id: row.id,
  mode: row.mode as MemoMode,
  device: row.device,
  startedAt: row.started_at,
  state: row.state as MemoState,
  failedStep: row.failed_step as Step | null,
  error: row.error,
  segmentCount: row.segment_count,
  audioSeconds: row.audio_seconds,
  transcript: row.transcript,
  route: row.route,
  destinationRef: row.destination_ref,
  replyText: row.reply_text,
  summary: parseSummary(row),
  threadId: row.thread_id,
  ...(row.park_reason !== null && { routeReason: row.park_reason }),
  ...(row.park_destination !== null && { routeSuggestion: row.park_destination }),
  createdAt: row.created_at,
  updatedAt: row.updated_at,
});

/** `SELECT` list for a memo row: the columns plus the park details of the latest routing decision. */
const MEMO_SELECT = `memos.*,
  CASE WHEN memos.state = 'needs_route' THEN
    (SELECT reason FROM route_decisions d WHERE d.memo_id = memos.id ORDER BY d.id DESC LIMIT 1) END AS park_reason,
  CASE WHEN memos.state = 'needs_route' THEN
    (SELECT destination FROM route_decisions d WHERE d.memo_id = memos.id ORDER BY d.id DESC LIMIT 1) END AS park_destination`;

const toRouteDecision = (row: RouteDecisionRow): RouteDecisionRecord => ({
  id: row.id,
  memoId: row.memo_id,
  createdAt: row.created_at,
  source: row.source as RouteSource,
  destination: row.destination,
  tab: row.tab,
  confidence: row.confidence,
  model: row.model,
  costUsd: row.cost_usd,
  reason: row.reason,
  outcome: row.outcome as RouteOutcome,
});

/** Column behind each patchable memo field. */
const PATCH_COLUMNS = {
  audioSeconds: "audio_seconds",
  transcript: "transcript",
  route: "route",
  destinationRef: "destination_ref",
  replyText: "reply_text",
  summary: "summary_json",
  threadId: "thread_id",
} as const satisfies Record<keyof MemoColumnPatch, string>;

/** The data columns a step writes, cleared when the step is re-run. */
const STEP_COLUMNS: Partial<Record<Step, (keyof MemoColumnPatch)[]>> = {
  transcribe: ["audioSeconds", "transcript"],
  route: ["route"],
  act: ["destinationRef", "replyText", "threadId"],
  summarize: ["summary"],
};

const toStepRecord = (row: StepRow): StepRecord => ({
  step: row.step as Step,
  status: row.status as StepRecord["status"],
  startedAt: row.started_at,
  finishedAt: row.finished_at,
  error: row.error,
  usage: row.usage_json === null ? null : (JSON.parse(row.usage_json) as unknown),
  costUsd: row.cost_usd,
});

export function createSqliteMemoStore(params: { db: Database; clock: Clock }): MemoStore {
  const { db, clock } = params;
  db.exec("PRAGMA foreign_keys = ON");
  migrate(db);

  const stamp = () => clock.now().toISOString();
  const memoById = (id: string) =>
    db.query<MemoRow, [string]>(`SELECT ${MEMO_SELECT} FROM memos WHERE id = ?`).get(id);

  const markStepFailed = db.transaction((id: string, step: Step, error: string) => {
    const at = stamp();
    db.query(
      "UPDATE memo_steps SET status = 'failed', finished_at = ?, error = ? WHERE memo_id = ? AND step = ?",
    ).run(at, error, id, step);
    db.query(
      "UPDATE memos SET state = 'failed', failed_step = ?, error = ?, updated_at = ? WHERE id = ?",
    ).run(step, error, at, id);
  });

  const resetForRetry = db.transaction((id: string, from: Step) => {
    const reset = db
      .query(
        "UPDATE memos SET state = ?, failed_step = NULL, error = NULL, updated_at = ? WHERE id = ? AND state = 'failed'",
      )
      .run(stateBefore(from), stamp(), id);
    if (reset.changes === 0) return false;
    const cleared = stepsFrom(from);
    const columns = cleared
      .flatMap((step) => STEP_COLUMNS[step] ?? [])
      .map((f) => PATCH_COLUMNS[f]);
    if (columns.length > 0) {
      db.query(`UPDATE memos SET ${columns.map((c) => `${c} = NULL`).join(", ")} WHERE id = ?`).run(
        id,
      );
    }
    db.query(
      `DELETE FROM memo_steps WHERE memo_id = ? AND step IN (${cleared.map(() => "?").join(",")})`,
    ).run(id, ...cleared);
    return true;
  });

  const insertRouteDecision = (id: string, at: string, decision: RouteDecisionInput) => {
    db.query(
      `INSERT INTO route_decisions
         (memo_id, created_at, source, destination, tab, confidence, model, cost_usd, reason, outcome)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).run(
      id,
      at,
      decision.source,
      decision.destination,
      decision.tab,
      decision.confidence,
      decision.model,
      decision.costUsd,
      decision.reason,
      decision.outcome,
    );
  };

  /** Creates the thread, or bumps `updated_at` and `last_memo_id` of an existing one (its kind and title stay). The memo's `thread_id` is a patched column. */
  const upsertThread = (memoId: string, at: string, thread: ThreadUpsert) => {
    db.query(
      `INSERT INTO threads (id, kind, title, created_at, updated_at, last_memo_id)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET updated_at = excluded.updated_at, last_memo_id = excluded.last_memo_id`,
    ).run(thread.id, thread.kind, thread.title, at, at, memoId);
  };

  const answerRoute = db.transaction((id: string, decision: AnswerDecision): boolean => {
    const at = stamp();
    const moved = db
      .query(
        "UPDATE memos SET state = 'routed', route = ?, updated_at = ? WHERE id = ? AND state = 'needs_route'",
      )
      .run(decision.destination, at, id);
    if (moved.changes === 0) return false;
    insertRouteDecision(id, at, decision);
    return true;
  });

  const recordCorrection = db.transaction((id: string, decision: RouteDecisionInput): boolean => {
    const row = db
      .query<{ state: string }, [string]>("SELECT state FROM memos WHERE id = ?")
      .get(id);
    if (!row || !isCorrectable(row.state as MemoState)) return false;
    insertRouteDecision(id, stamp(), decision);
    return true;
  });

  const completeStep = db.transaction(
    (input: Parameters<MemoStore["completeStep"]>[0]): boolean => {
      const { id, step, from, to, usage, costUsd, patch } = input;
      const at = stamp();
      const moved = db
        .query("UPDATE memos SET state = ?, updated_at = ? WHERE id = ? AND state = ?")
        .run(to, at, id, from);
      if (moved.changes === 0) return false;
      db.query(
        `UPDATE memo_steps SET status = 'done', finished_at = ?, error = NULL, usage_json = ?, cost_usd = ?
         WHERE memo_id = ? AND step = ?`,
      ).run(at, usage === undefined ? null : JSON.stringify(usage), costUsd ?? null, id, step);
      if (patch?.routeDecision) insertRouteDecision(id, at, patch.routeDecision);
      if (patch?.thread) upsertThread(id, at, patch.thread);
      // A reported thread is also the memo's `thread_id`.
      const columns: MemoColumnPatch | undefined = patch?.thread
        ? { ...patch, threadId: patch.thread.id }
        : patch;
      const fields = (Object.keys(PATCH_COLUMNS) as (keyof MemoColumnPatch)[]).filter(
        (field) => columns?.[field] !== undefined,
      );
      if (fields.length === 0) return true;
      const values = fields.map((field) => {
        const value = columns?.[field];
        if (field !== "summary") return value as string | number | null;
        return value === null ? null : JSON.stringify(value);
      });
      db.query(
        `UPDATE memos SET ${fields.map((f) => `${PATCH_COLUMNS[f]} = ?`).join(", ")} WHERE id = ?`,
      ).run(...values, id);
      return true;
    },
  );

  return {
    createMemo({ id, mode, device, startedAt }) {
      const at = stamp();
      const inserted = db
        .query(
          `INSERT INTO memos (id, mode, device, started_at, state, created_at, updated_at)
           VALUES (?, ?, ?, ?, 'receiving', ?, ?) ON CONFLICT (id) DO NOTHING`,
        )
        .run(id, mode, device, startedAt, at, at);
      const row = memoById(id);
      if (!row) throw new Error(`memo ${id} vanished after insert`);
      return { memo: toMemo(row), created: inserted.changes === 1 };
    },

    createTextMemo({ id, mode, device, startedAt, text }) {
      const at = stamp();
      const inserted = db
        .query(
          `INSERT INTO memos (id, mode, device, started_at, state, transcript, created_at, updated_at)
           VALUES (?, ?, ?, ?, 'transcribed', ?, ?, ?) ON CONFLICT (id) DO NOTHING`,
        )
        .run(id, mode, device, startedAt, text, at, at);
      const row = memoById(id);
      if (!row) throw new Error(`memo ${id} vanished after insert`);
      return { memo: toMemo(row), created: inserted.changes === 1 };
    },

    getMemo(id) {
      const row = memoById(id);
      return row ? toMemo(row) : null;
    },

    listMemos({ limit, cursor }) {
      let before: number | null = null;
      if (cursor) {
        before = Number(cursor);
        if (!Number.isInteger(before) || before < 1) {
          throw new MemoError("bad_request", "invalid cursor");
        }
      }
      const rows = db
        .query<MemoRow, [number | null, number | null, number]>(
          `SELECT ${MEMO_SELECT} FROM memos WHERE (? IS NULL OR seq < ?) ORDER BY seq DESC LIMIT ?`,
        )
        .all(before, before, limit + 1);
      const page = rows.slice(0, limit);
      const last = page.at(-1);
      return {
        memos: page.map(toMemo),
        nextCursor: rows.length > limit && last ? String(last.seq) : null,
      };
    },

    recordSegment({ id, index, bytes, sha256 }) {
      const result = db
        .query(
          `INSERT INTO segments (memo_id, idx, bytes, sha256, received_at) VALUES (?, ?, ?, ?, ?)
           ON CONFLICT (memo_id, idx) DO NOTHING`,
        )
        .run(id, index, bytes, sha256, stamp());
      return result.changes === 1;
    },

    getSegment({ id, index }) {
      return db
        .query<{ bytes: number; sha256: string }, [string, number]>(
          "SELECT bytes, sha256 FROM segments WHERE memo_id = ? AND idx = ?",
        )
        .get(id, index);
    },

    listSegmentIndices(id) {
      return db
        .query<{ idx: number }, [string]>("SELECT idx FROM segments WHERE memo_id = ? ORDER BY idx")
        .all(id)
        .map((row) => row.idx);
    },

    deleteSegments(id) {
      db.query("DELETE FROM segments WHERE memo_id = ?").run(id);
    },

    markReceived({ id, segmentCount }) {
      const result = db
        .query(
          "UPDATE memos SET state = 'received', segment_count = ?, updated_at = ? WHERE id = ? AND state = 'receiving'",
        )
        .run(segmentCount, stamp(), id);
      return result.changes === 1;
    },

    transition({ id, from, to }) {
      const result = db
        .query("UPDATE memos SET state = ?, updated_at = ? WHERE id = ? AND state = ?")
        .run(to, stamp(), id, from);
      return result.changes === 1;
    },

    markStepStarted({ id, step }) {
      db.query(
        `INSERT OR REPLACE INTO memo_steps (memo_id, step, status, started_at)
         VALUES (?, ?, 'running', ?)`,
      ).run(id, step, stamp());
    },

    markStepDone({ id, step, usage, costUsd }) {
      db.query(
        `UPDATE memo_steps SET status = 'done', finished_at = ?, error = NULL, usage_json = ?, cost_usd = ?
         WHERE memo_id = ? AND step = ?`,
      ).run(stamp(), usage === undefined ? null : JSON.stringify(usage), costUsd ?? null, id, step);
    },

    completeStep(input) {
      return completeStep(input);
    },

    markStepFailed({ id, step, error }) {
      markStepFailed(id, step, error);
    },

    resetForRetry({ id, from }) {
      return resetForRetry(id, from);
    },

    listStepRecords(id) {
      const order = STEPS.map((step, i) => `WHEN '${step}' THEN ${i}`).join(" ");
      return db
        .query<StepRow, [string]>(
          `SELECT * FROM memo_steps WHERE memo_id = ? ORDER BY CASE step ${order} END`,
        )
        .all(id)
        .map(toStepRecord);
    },

    listRouteDecisions(id) {
      return db
        .query<RouteDecisionRow, [string]>(
          "SELECT * FROM route_decisions WHERE memo_id = ? ORDER BY id",
        )
        .all(id)
        .map(toRouteDecision);
    },

    answerRoute({ id, decision }) {
      return answerRoute(id, decision);
    },

    recordCorrection({ id, decision }) {
      return recordCorrection(id, decision);
    },

    listNonTerminal() {
      return db
        .query<MemoRow, []>(
          `SELECT ${MEMO_SELECT} FROM memos
           WHERE state NOT IN ('receiving', 'notified', 'failed', 'needs_route') ORDER BY seq`,
        )
        .all()
        .map(toMemo);
    },
  };
}
