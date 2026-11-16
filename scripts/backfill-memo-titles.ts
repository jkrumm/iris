#!/usr/bin/env bun
/**
 * One-off, idempotent: gives every finished transcribe-mode memo that has no summary the headline (and, for a long
 * transcript, the gist) that `summarize` now writes for a new one. Notifies nobody: only the memo row and a `summarize`
 * step row change. A memo that already has a summary is never touched, so a second run (or a rerun after a failure) only
 * does what is left.
 *
 *   secrets-run run --env-file=.env.local.tpl --env-file=.env.mini.tpl -- \
 *     env IRIS_DATA="$HOME/.iris/data" bun scripts/backfill-memo-titles.ts [--dry-run]
 *
 * Run it once after the deploy that added `transcript_gist` (the server's boot migration creates the column).
 * Exit 0 when nothing is left, 1 when a memo failed (rerun), 2 on a usage or environment error.
 */
import { Database } from "bun:sqlite";
import { join } from "node:path";
import { createAgwClient } from "../server/src/adapters/agw-client.js";
import { createAgwSummarizer } from "../server/src/adapters/agw.js";
import { needsGist, TRANSCRIBE_ROUTE } from "../server/src/memo/memo.js";
import type { Summarizer } from "../server/src/ports/summarizer.js";

interface Candidate {
  id: string;
  transcript: string;
}

export interface BackfillResult {
  /** Memos that got a summary this run. */
  titled: number;
  /** Of those, the ones that also got a gist. */
  gisted: number;
  /** Memos whose summarize call failed; they stay untouched for the next run. */
  failed: number;
}

/** The memos still to do: finished, not deleted, transcript present, no summary yet. */
export function candidates(db: Database): Candidate[] {
  return db
    .query<Candidate, []>(
      `SELECT id, transcript FROM memos
       WHERE mode = 'transcribe' AND state = 'notified' AND deleted_at IS NULL
         AND summary_json IS NULL AND transcript IS NOT NULL AND trim(transcript) != ''
       ORDER BY seq`,
    )
    .all();
}

export async function backfillTitles(params: {
  db: Database;
  summarizer: Summarizer;
  dryRun?: boolean;
  now?: () => Date;
  log?: (line: string) => void;
}): Promise<BackfillResult> {
  const { db, summarizer, dryRun = false, now = () => new Date(), log = () => {} } = params;
  const result: BackfillResult = { titled: 0, gisted: 0, failed: 0 };
  const write = db.transaction((id: string, summary: string, gist: string | null, at: string) => {
    const changed = db
      .query(
        `UPDATE memos SET summary_json = ?, transcript_gist = ?, updated_at = ? WHERE id = ? AND summary_json IS NULL`,
      )
      .run(summary, gist, at, id).changes;
    if (changed === 0) return false;
    db.query(
      `INSERT OR IGNORE INTO memo_steps (memo_id, step, status, started_at, finished_at, attempts)
       VALUES (?, 'summarize', 'done', ?, ?, 1)`,
    ).run(id, at, at);
    return true;
  });

  for (const { id, transcript } of candidates(db)) {
    if (dryRun) {
      result.titled++;
      continue;
    }
    try {
      const [{ summary }, gist] = await Promise.all([
        summarizer.summarize({ memoId: id, route: TRANSCRIBE_ROUTE, transcript, replyText: null }),
        needsGist(transcript)
          ? summarizer.gist({ memoId: id, transcript }).catch((err: unknown) => {
              log(`gist failed for ${id}: ${String(err)}`);
              return null;
            })
          : null,
      ]);
      if (!write(id, JSON.stringify(summary), gist, now().toISOString())) continue;
      result.titled++;
      if (gist !== null) result.gisted++;
      log(`titled ${id}`);
    } catch (err) {
      result.failed++;
      log(`summarize failed for ${id}: ${String(err)}`);
    }
  }
  return result;
}

async function main() {
  const dryRun = process.argv.includes("--dry-run");
  const { IRIS_DATA, AGW_URL, AGW_API_SECRET } = process.env;
  if (!IRIS_DATA || !AGW_URL || !AGW_API_SECRET) {
    console.error("backfill: IRIS_DATA, AGW_URL and AGW_API_SECRET must be set (see the header)");
    process.exit(2);
  }
  const db = new Database(join(IRIS_DATA, "iris.db"), { readwrite: true });
  db.exec("PRAGMA busy_timeout = 30000");
  const columns = db.query<{ name: string }, []>("PRAGMA table_info(memos)").all();
  if (!columns.some((c) => c.name === "transcript_gist")) {
    console.error(
      "backfill: memos.transcript_gist is missing; deploy the server first (it migrates on boot)",
    );
    process.exit(2);
  }
  const summarizer = createAgwSummarizer({
    client: createAgwClient({ baseUrl: AGW_URL, secret: AGW_API_SECRET }),
  });
  const result = await backfillTitles({ db, summarizer, dryRun, log: (line) => console.log(line) });
  console.log(
    `backfill: ${dryRun ? "would title" : "titled"} ${result.titled} memos (${result.gisted} with a gist), ${result.failed} failed`,
  );
  db.close();
  process.exit(result.failed > 0 ? 1 : 0);
}

if (import.meta.main) await main();
