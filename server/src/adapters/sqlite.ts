import { Database } from "bun:sqlite";
import { z } from "zod";
import { MemoError } from "../memo/errors.js";
import {
  groupReplyBlocks,
  STEPS,
  isOptionalStep,
  stateAfter,
  stateBefore,
  stepsFrom,
  type Memo,
  type MemoColumnPatch,
  type MemoMode,
  type MemoState,
  type ReplyAsset,
  type Step,
  type StepRecord,
  type Summary,
  type ThreadUpsert,
} from "../memo/memo.js";
import type { MemoStore, StagedReplyAssets, ThreadStore } from "../memo/store.js";
import type { Clock } from "../ports/clock.js";
import { log } from "../telemetry/log.js";
import { MIGRATIONS } from "./sqlite-migrations.js";
import { createSqliteThreadStore } from "./sqlite-threads.js";

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
  mode: MemoMode;
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
  kind: string | null;
  /** The headline of Hermes's iris block, NULL before `act` and when the reply carried none. */
  hermes_headline: string | null;
  /** The tool names of the turn as a JSON array of strings, NULL before `act`. */
  actions_json: string | null;
  done: number;
  favorite: number;
  archived_at: string | null;
  deleted_at: string | null;
  created_at: string;
  updated_at: string;
  /** The memo's `reply_assets` rows as a JSON array (`REPLY_ASSETS_JSON`), `[]` when it has none. */
  reply_assets_json: string;
}

interface ReplyAssetRow {
  id: string;
  block_index: number;
  format: string;
  scheme: string;
  width: number;
  height: number;
}

const toReplyAsset = (row: ReplyAssetRow): ReplyAsset => ({
  id: row.id,
  block: row.block_index,
  format: row.format as ReplyAsset["format"],
  scheme: row.scheme as ReplyAsset["scheme"],
  width: row.width,
  height: row.height,
});

interface StepRow {
  step: string;
  status: string;
  started_at: string;
  finished_at: string | null;
  error: string | null;
  usage_json: string | null;
  cost_usd: number | null;
  attempts: number;
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

const ActionsSchema = z.array(z.string());

/** Like the summary: a stored list that no longer parses reads as none, with a warning. */
function parseActions(row: MemoRow): string[] {
  if (row.actions_json === null) return [];
  try {
    const parsed = ActionsSchema.safeParse(JSON.parse(row.actions_json));
    if (parsed.success) return parsed.data;
    log("memo.actions_invalid", { memo_id: row.id, error: parsed.error.message });
  } catch (err) {
    log("memo.actions_invalid", { memo_id: row.id, error: String(err) });
  }
  return [];
}

const ReplyAssetsSchema = z.array(
  z.object({
    id: z.string(),
    block_index: z.number(),
    format: z.enum(["svg", "png"]),
    scheme: z.enum(["light", "dark"]),
    width: z.number(),
    height: z.number(),
  }),
);

/** Like the summary: rows that no longer parse drop the blocks (the reply stays plain markdown) with a warning, never a failed read. */
function parseReplyBlocks(row: MemoRow) {
  try {
    const parsed = ReplyAssetsSchema.safeParse(JSON.parse(row.reply_assets_json));
    if (parsed.success) return groupReplyBlocks(parsed.data.map(toReplyAsset));
    log("memo.reply_assets_invalid", { memo_id: row.id, error: parsed.error.message });
  } catch (err) {
    log("memo.reply_assets_invalid", { memo_id: row.id, error: String(err) });
  }
  return [];
}

const toMemo = (row: MemoRow): Memo => ({
  id: row.id,
  mode: row.mode,
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
  replyBlocks: parseReplyBlocks(row),
  summary: parseSummary(row),
  threadId: row.thread_id,
  kind: row.kind,
  hermesHeadline: row.hermes_headline,
  actions: parseActions(row),
  done: row.done === 1,
  favorite: row.favorite === 1,
  archivedAt: row.archived_at,
  deletedAt: row.deleted_at,
  createdAt: row.created_at,
  updatedAt: row.updated_at,
});

const REPLY_ASSETS_JSON = `(SELECT json_group_array(json_object(
    'id', a.id, 'block_index', a.block_index, 'format', a.format, 'scheme', a.scheme, 'width', a.width, 'height', a.height))
  FROM reply_assets a WHERE a.memo_id = memos.id)`;

/** `SELECT` list for a memo row: the columns and the reply's rendered blocks. */
const MEMO_SELECT = `memos.*, ${REPLY_ASSETS_JSON} AS reply_assets_json`;

/**
 * The FTS5 MATCH expression for a user's search text: every term quoted (embedded quotes doubled, so input
 * never reaches the MATCH syntax as an operator) and prefix-matched, terms ANDed. `undefined`: no search
 * (blank text). `null`: text without a single letter or digit, which matches nothing.
 */
function ftsMatch(q: string): string | null | undefined {
  const words = q.split(/\s+/).filter(Boolean);
  if (words.length === 0) return undefined;
  const terms = words.filter((word) => /[\p{L}\p{N}]/u.test(word));
  if (terms.length === 0) return null;
  return terms.map((term) => `"${term.replaceAll('"', '""')}"*`).join(" ");
}

/** Column behind each patchable memo field. */
const PATCH_COLUMNS = {
  audioSeconds: "audio_seconds",
  transcript: "transcript",
  destinationRef: "destination_ref",
  replyText: "reply_text",
  summary: "summary_json",
  threadId: "thread_id",
  kind: "kind",
  hermesHeadline: "hermes_headline",
  actions: "actions_json",
} as const satisfies Record<keyof MemoColumnPatch, string>;

/** The data columns a step writes, cleared when the step is re-run. */
const STEP_COLUMNS: Partial<Record<Step, (keyof MemoColumnPatch)[]>> = {
  transcribe: ["audioSeconds", "transcript"],
  act: ["destinationRef", "replyText", "kind", "hermesHeadline", "actions"],
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
  attempts: row.attempts,
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

  const skipStep = db.transaction((id: string, step: Step, from: MemoState, error: string) => {
    if (!isOptionalStep(step)) throw new Error(`step ${step} is not optional`);
    const at = stamp();
    const moved = db
      .query("UPDATE memos SET state = ?, updated_at = ? WHERE id = ? AND state = ?")
      .run(stateAfter(step), at, id, from);
    if (moved.changes === 0) return false;
    db.query(
      "UPDATE memo_steps SET status = 'failed', finished_at = ?, error = ? WHERE memo_id = ? AND step = ?",
    ).run(at, error, id, step);
    return true;
  });

  const resetForRetry = db.transaction((id: string, from: Step) => {
    const mode = memoById(id)?.mode;
    if (mode === undefined) return false;
    // A failed memo, or a finished one whose optional step failed on the way (`from` is that step).
    const reset = db
      .query(
        `UPDATE memos SET state = ?, failed_step = NULL, error = NULL, updated_at = ? WHERE id = ?
           AND (state = 'failed' OR (state = 'notified' AND EXISTS (
             SELECT 1 FROM memo_steps WHERE memo_id = memos.id AND step = ? AND status = 'failed')))`,
      )
      .run(stateBefore({ step: from, mode }), stamp(), id, from);
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
    // `route` is the destination of a memo from before Hermes decided: re-running into Hermes must not keep the stale chip.
    if (cleared.includes("act")) {
      db.query("UPDATE memos SET route = NULL WHERE id = ?").run(id);
    }
    // `act` set the memo's own session; a memo created to continue a thread keeps its thread (its `thread_id` is never its id).
    if (cleared.includes("act")) {
      db.query("UPDATE memos SET thread_id = NULL WHERE id = ? AND thread_id = id").run(id);
      // The reply they were rendered from is gone; their files go with the next render or the purge.
      db.query("DELETE FROM reply_assets WHERE memo_id = ?").run(id);
      db.query("UPDATE memos SET reply_assets_failed = 0 WHERE id = ?").run(id);
    }
    db.query(
      `DELETE FROM memo_steps WHERE memo_id = ? AND step IN (${cleared.map(() => "?").join(",")})`,
    ).run(id, ...cleared);
    return true;
  });

  /** Creates the thread, or bumps `updated_at` and `last_memo_id` of an existing one (its kind and title stay). The memo's `thread_id` is a patched column. */
  const upsertThread = (memoId: string, at: string, thread: ThreadUpsert) => {
    db.query(
      `INSERT INTO threads (id, kind, title, created_at, updated_at, last_memo_id)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET updated_at = excluded.updated_at, last_memo_id = excluded.last_memo_id`,
    ).run(thread.id, thread.kind, thread.title, at, at, memoId);
  };

  const insertReplyAssets = (id: string, assets: readonly ReplyAsset[]) => {
    const insert = db.query(
      `INSERT INTO reply_assets (memo_id, id, block_index, format, scheme, width, height)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    );
    for (const a of assets) insert.run(id, a.id, a.block, a.format, a.scheme, a.width, a.height);
  };

  /** Reply assets awaiting their reply's commit, by memo (`MemoStore.stageReplyAssets`). */
  const stagedAssets = new Map<string, StagedReplyAssets>();

  const completeStep = db.transaction(
    (input: Parameters<MemoStore["completeStep"]>[0]): boolean => {
      const { id, step, from, to, usage, costUsd, patch } = input;
      const at = stamp();
      const moved = db
        .query("UPDATE memos SET state = ?, updated_at = ? WHERE id = ? AND state = ?")
        .run(to, at, id, from);
      // A lost compare-and-set changes nothing: the rows of an earlier committed reply stay.
      if (moved.changes === 0) return false;
      // A committed reply brings its own assets (rendered before this commit) or none: the rows of the reply it replaces go.
      const replyText = patch?.replyText;
      if (replyText !== undefined) {
        const staged = stagedAssets.get(id);
        const own = staged?.replyText === replyText ? staged : undefined;
        db.query("DELETE FROM reply_assets WHERE memo_id = ?").run(id);
        insertReplyAssets(id, own?.assets ?? []);
        db.query("UPDATE memos SET reply_assets_failed = ? WHERE id = ?").run(
          own?.failed ? 1 : 0,
          id,
        );
      }
      db.query(
        `UPDATE memo_steps SET status = 'done', finished_at = ?, error = NULL, usage_json = ?, cost_usd = ?
         WHERE memo_id = ? AND step = ?`,
      ).run(at, usage === undefined ? null : JSON.stringify(usage), costUsd ?? null, id, step);
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
        if (field !== "summary" && field !== "actions") return value as string | number | null;
        return value === null ? null : JSON.stringify(value);
      });
      db.query(
        `UPDATE memos SET ${fields.map((f) => `${PATCH_COLUMNS[f]} = ?`).join(", ")} WHERE id = ?`,
      ).run(...values, id);
      return true;
    },
  );

  const attachReplyAssets = db.transaction(
    (params: { id: string; replyText: string; assets: readonly ReplyAsset[] }): boolean => {
      const { id, replyText, assets } = params;
      const live = db
        .query("SELECT 1 FROM memos WHERE id = ? AND deleted_at IS NULL AND reply_text = ?")
        .get(id, replyText);
      if (!live || db.query("SELECT 1 FROM reply_assets WHERE memo_id = ?").get(id)) return false;
      insertReplyAssets(id, assets);
      return true;
    },
  );

  const purge = db.transaction((id: string): boolean => {
    const row = db
      .query<{ thread_id: string | null }, [string]>(
        "SELECT thread_id FROM memos WHERE id = ? AND deleted_at IS NOT NULL",
      )
      .get(id);
    if (!row) return false;
    // Children (steps, segments, decisions, activity tokens) go with the row by ON DELETE CASCADE.
    db.query("DELETE FROM memos WHERE id = ?").run(id);
    const threadId = row.thread_id;
    if (threadId !== null) {
      db.query(
        `UPDATE threads SET last_memo_id = (SELECT m.id FROM memos m WHERE m.thread_id = threads.id ORDER BY m.seq DESC LIMIT 1)
         WHERE id = ? AND last_memo_id = ?`,
      ).run(threadId, id);
      db.query(
        "DELETE FROM threads WHERE id = ? AND NOT EXISTS (SELECT 1 FROM memos m WHERE m.thread_id = threads.id)",
      ).run(threadId);
    }
    return true;
  });

  const memoStore: Omit<MemoStore, keyof ThreadStore> = {
    createMemo({ id, mode, device, startedAt, threadId }) {
      const at = stamp();
      const inserted = db
        .query(
          `INSERT INTO memos (id, mode, device, started_at, state, thread_id, created_at, updated_at)
           VALUES (?, ?, ?, ?, 'receiving', ?, ?, ?) ON CONFLICT (id) DO NOTHING`,
        )
        .run(id, mode, device, startedAt, threadId ?? null, at, at);
      const row = memoById(id);
      if (!row) throw new Error(`memo ${id} vanished after insert`);
      return { memo: toMemo(row), created: inserted.changes > 0 };
    },

    createTextMemo({ id, mode, device, startedAt, text, threadId }) {
      const at = stamp();
      const inserted = db
        .query(
          `INSERT INTO memos (id, mode, device, started_at, state, transcript, thread_id, created_at, updated_at)
           VALUES (?, ?, ?, ?, 'transcribed', ?, ?, ?, ?) ON CONFLICT (id) DO NOTHING`,
        )
        .run(id, mode, device, startedAt, text, threadId ?? null, at, at);
      const row = memoById(id);
      if (!row) throw new Error(`memo ${id} vanished after insert`);
      return { memo: toMemo(row), created: inserted.changes > 0 };
    },

    getMemo(id) {
      const row = memoById(id);
      return row ? toMemo(row) : null;
    },

    listMemos({ limit, cursor, q, kind, state, favorite, archived, thread }) {
      let before: number | null = null;
      if (cursor) {
        before = Number(cursor);
        if (!Number.isInteger(before) || before < 1) {
          throw new MemoError("bad_request", "invalid cursor");
        }
      }
      const filters: string[] = [
        "memos.deleted_at IS NULL",
        archived ? "memos.archived_at IS NOT NULL" : "memos.archived_at IS NULL",
      ];
      const args: (string | number)[] = [];
      if (favorite) filters.push("memos.favorite = 1");
      // A conversation: a thread with at least two live memos (a continued one). Every acted memo has a session of its own.
      if (thread) {
        filters.push(
          `memos.thread_id IN (SELECT thread_id FROM memos WHERE thread_id IS NOT NULL AND deleted_at IS NULL
             GROUP BY thread_id HAVING count(*) >= 2)`,
        );
      }
      if (kind !== undefined) {
        filters.push("memos.kind = ?");
        args.push(kind);
      }
      if (state) {
        filters.push("memos.state = ?");
        args.push(state);
      }
      const match = q === undefined ? undefined : ftsMatch(q);
      if (match === null) filters.push("0");
      else if (match !== undefined) {
        filters.push("memos.seq IN (SELECT rowid FROM memo_fts WHERE memo_fts MATCH ?)");
        args.push(match);
      }
      if (before !== null) filters.push("memos.seq < ?");
      const rows = db
        .query<MemoRow, (string | number)[]>(
          `SELECT ${MEMO_SELECT} FROM memos WHERE ${filters.join(" AND ")} ORDER BY seq DESC LIMIT ?`,
        )
        .all(...args, ...(before === null ? [] : [before]), limit + 1);
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
          "UPDATE memos SET state = 'received', segment_count = ?, updated_at = ? WHERE id = ? AND state = 'receiving' AND deleted_at IS NULL",
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

    markStepRetrying({ id, step, error }) {
      const result = db
        .query(
          "UPDATE memo_steps SET attempts = attempts + 1, error = ? WHERE memo_id = ? AND step = ? AND status = 'running'",
        )
        .run(error, id, step);
      if (result.changes !== 1) return null;
      return (
        db
          .query<{ attempts: number }, [string, string]>(
            "SELECT attempts FROM memo_steps WHERE memo_id = ? AND step = ?",
          )
          .get(id, step)?.attempts ?? null
      );
    },

    markStepDone({ id, step, usage, costUsd }) {
      db.query(
        `UPDATE memo_steps SET status = 'done', finished_at = ?, error = NULL, usage_json = ?, cost_usd = ?
         WHERE memo_id = ? AND step = ?`,
      ).run(stamp(), usage === undefined ? null : JSON.stringify(usage), costUsd ?? null, id, step);
    },

    completeStep(input) {
      const text = input.patch?.replyText;
      const staged = stagedAssets.get(input.id);
      let won: boolean;
      try {
        won = completeStep(input);
      } catch (err) {
        // The transaction rolled back: the staged reply never commits, so its files must not be left behind.
        if (text !== undefined && staged?.replyText === text) {
          stagedAssets.delete(input.id);
          staged.onSettled("discarded");
        }
        throw err;
      }
      // The reply the staged assets were rendered for is settled either way; the rows were handled in the transaction.
      if (text !== undefined && staged?.replyText === text) {
        stagedAssets.delete(input.id);
        staged.onSettled(won ? "committed" : "discarded");
      }
      return won;
    },

    markStepFailed({ id, step, error }) {
      markStepFailed(id, step, error);
    },

    skipStep({ id, step, from, error }) {
      return skipStep(id, step, from, error);
    },
    resetForRetry({ id, from }) {
      const reset = resetForRetry(id, from);
      // The transaction dropped the rows of a reply that is gone; no completeStep will settle its staged assets.
      const staged = stagedAssets.get(id);
      if (reset && staged && stepsFrom(from).includes("act")) {
        stagedAssets.delete(id);
        staged.onSettled("discarded");
      }
      return reset;
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

    setFlags({ id, done, favorite, archived }) {
      const sets: string[] = [];
      const args: (string | number)[] = [];
      const at = stamp();
      if (done !== undefined) {
        sets.push("done = ?");
        args.push(done ? 1 : 0);
      }
      if (favorite !== undefined) {
        sets.push("favorite = ?");
        args.push(favorite ? 1 : 0);
      }
      if (archived === true) {
        sets.push("archived_at = COALESCE(archived_at, ?)");
        args.push(at);
      } else if (archived === false) {
        sets.push("archived_at = NULL");
      }
      if (sets.length === 0) return memoById(id) !== null;
      const result = db
        .query(
          `UPDATE memos SET ${sets.join(", ")}, updated_at = ? WHERE id = ? AND deleted_at IS NULL`,
        )
        .run(...args, at, id);
      return result.changes === 1;
    },

    markDeleted({ id, at }) {
      db.query(
        "UPDATE memos SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL",
      ).run(at, stamp(), id);
      return memoById(id) !== null;
    },

    restore(id) {
      const result = db
        .query(
          "UPDATE memos SET deleted_at = NULL, updated_at = ? WHERE id = ? AND deleted_at IS NOT NULL",
        )
        .run(stamp(), id);
      return result.changes === 1;
    },

    listPurgeable(cutoff) {
      return db
        .query<{ id: string }, [string]>(
          "SELECT id FROM memos WHERE deleted_at IS NOT NULL AND deleted_at <= ? ORDER BY deleted_at, seq",
        )
        .all(cutoff)
        .map((row) => row.id);
    },

    purge(id) {
      const purged = purge(id);
      if (purged) stagedAssets.delete(id);
      return purged;
    },

    stageReplyAssets(id, staged) {
      if (!db.query("SELECT 1 FROM memos WHERE id = ?").get(id)) return false;
      const older = stagedAssets.get(id);
      stagedAssets.set(id, staged);
      // Its caller is done with it: the newer staging owns the memo's next commit.
      if (older) older.onSettled("discarded");
      return true;
    },

    attachReplyAssets(params) {
      return attachReplyAssets(params);
    },

    listReplyAssetCandidates({ beforeSeq, limit }) {
      return db
        .query<{ id: string; seq: number; reply_text: string }, [number, number]>(
          `SELECT id, seq, reply_text FROM memos
           WHERE deleted_at IS NULL AND reply_text LIKE '%mermaid%' AND seq < ?
             AND reply_assets_failed = 0
             AND NOT EXISTS (SELECT 1 FROM reply_assets a WHERE a.memo_id = memos.id)
           ORDER BY seq DESC LIMIT ?`,
        )
        .all(beforeSeq ?? Number.MAX_SAFE_INTEGER, limit)
        .map((row) => ({ id: row.id, seq: row.seq, replyText: row.reply_text }));
    },

    markReplyAssetsFailed({ id, replyText }) {
      const result = db
        .query("UPDATE memos SET reply_assets_failed = 1 WHERE id = ? AND reply_text = ?")
        .run(id, replyText);
      return result.changes === 1;
    },

    getReplyAsset(id, assetId) {
      const row = db
        .query<ReplyAssetRow, [string, string]>(
          "SELECT id, block_index, format, scheme, width, height FROM reply_assets WHERE memo_id = ? AND id = ?",
        )
        .get(id, assetId);
      return row ? toReplyAsset(row) : null;
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

  return {
    ...memoStore,
    ...createSqliteThreadStore({
      db,
      memosOfThread: (threadId) =>
        db
          .query<MemoRow, [string]>(
            `SELECT ${MEMO_SELECT} FROM memos WHERE thread_id = ? AND deleted_at IS NULL ORDER BY seq`,
          )
          .all(threadId)
          .map(toMemo),
    }),
  };
}
