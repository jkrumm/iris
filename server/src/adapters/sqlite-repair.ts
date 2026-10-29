import type { Database } from "bun:sqlite";
import { join } from "node:path";
import type { Clock } from "../ports/clock.js";
import { log } from "../telemetry/log.js";

/**
 * Boot-time repair for Wave 16 (summarize is optional): a memo that `failed` at `summarize` with a reply has everything the
 * user asked for, so it moves to `notified` (no push) and keeps its failed `summarize` step row. Idempotent: the repaired
 * memos no longer match. Before it touches a row it copies the database to `<dataDir>/iris.db.bak-<timestamp>`
 * (`VACUUM INTO`, a consistent snapshot); a run with nothing to repair writes no backup. Returns the memos moved.
 */
export function repairFailedSummaries(params: {
  db: Database;
  clock: Clock;
  dataDir: string;
}): number {
  const { db, clock, dataDir } = params;
  const candidates = `state = 'failed' AND failed_step = 'summarize' AND reply_text IS NOT NULL AND trim(reply_text) <> ''`;
  const pending =
    db.query<{ n: number }, []>(`SELECT count(*) AS n FROM memos WHERE ${candidates}`).get()?.n ??
    0;
  if (pending === 0) return 0;

  const at = clock.now().toISOString();
  const backup = join(dataDir, `iris.db.bak-${at.replace(/[:.]/g, "-")}`);
  db.query("VACUUM INTO ?").run(backup);
  const moved = db
    .query(
      `UPDATE memos SET state = 'notified', failed_step = NULL, error = NULL, updated_at = ? WHERE ${candidates}`,
    )
    .run(at).changes;
  log("repair.failed_summaries", { moved, backup });
  return moved;
}
