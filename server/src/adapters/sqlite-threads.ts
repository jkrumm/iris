import type { Database } from "bun:sqlite";
import { MemoError } from "../memo/errors.js";
import type { Memo, Thread, ThreadKind } from "../memo/memo.js";
import type { ThreadStore } from "../memo/store.js";

interface ThreadRow {
  id: string;
  kind: string;
  title: string;
  created_at: string;
  updated_at: string;
  last_memo_id: string | null;
}

const toThread = (row: ThreadRow): Thread => ({
  id: row.id,
  kind: row.kind as ThreadKind,
  title: row.title,
  createdAt: row.created_at,
  updatedAt: row.updated_at,
  lastMemoId: row.last_memo_id,
});

const encodeCursor = (row: ThreadRow) =>
  Buffer.from(JSON.stringify([row.updated_at, row.id])).toString("base64url");

function decodeCursor(cursor: string): { updatedAt: string; id: string } {
  try {
    const parsed: unknown = JSON.parse(Buffer.from(cursor, "base64url").toString());
    if (
      Array.isArray(parsed) &&
      parsed.length === 2 &&
      typeof parsed[0] === "string" &&
      typeof parsed[1] === "string"
    ) {
      return { updatedAt: parsed[0], id: parsed[1] };
    }
  } catch {
    // fall through to the error below
  }
  throw new MemoError("bad_request", "invalid cursor");
}

/**
 * The thread read model over the memo database. The rows are written by the memo store's `completeStep`
 * (`act` upserts the thread it ran in); `getMemo` is the memo store's, so a thread's memos serialize like any other.
 */
export function createSqliteThreadStore(params: {
  db: Database;
  getMemo: (id: string) => Memo | null;
}): ThreadStore {
  const { db, getMemo } = params;
  return {
    getThread(id) {
      const row = db.query<ThreadRow, [string]>("SELECT * FROM threads WHERE id = ?").get(id);
      return row ? toThread(row) : null;
    },

    listThreads({ kind, limit, cursor }) {
      const after = cursor == null ? null : decodeCursor(cursor);
      const rows = db
        .query<ThreadRow, (string | number | null)[]>(
          `SELECT * FROM threads
           WHERE (? IS NULL OR kind = ?)
             AND (? IS NULL OR updated_at < ? OR (updated_at = ? AND id < ?))
           ORDER BY updated_at DESC, id DESC LIMIT ?`,
        )
        .all(
          kind ?? null,
          kind ?? null,
          after?.updatedAt ?? null,
          after?.updatedAt ?? null,
          after?.updatedAt ?? null,
          after?.id ?? null,
          limit + 1,
        );
      const page = rows.slice(0, limit);
      const last = page.at(-1);
      return {
        threads: page.map(toThread),
        nextCursor: rows.length > limit && last ? encodeCursor(last) : null,
      };
    },

    listThreadMemos(id) {
      return db
        .query<{ id: string }, [string]>("SELECT id FROM memos WHERE thread_id = ? ORDER BY seq")
        .all(id)
        .flatMap((row) => getMemo(row.id) ?? []);
    },
  };
}
