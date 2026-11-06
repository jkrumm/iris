import type { Database } from "bun:sqlite";
import type { Clock } from "../ports/clock.js";
import type { FactoryPushStore } from "../ports/factory.js";
import { migrate } from "./sqlite.js";

/** Marks the first-ever scan; an ask id never looks like this. */
const BASELINE = "*baseline*";

/** `factory_ask_pushes` over the same database as the memo store. */
export function createSqliteFactoryPushStore(params: {
  db: Database;
  clock: Clock;
}): FactoryPushStore {
  const { db, clock } = params;
  migrate(db);
  const now = () => clock.now().toISOString();

  const insert = (askId: string, pushedAt: string | null) =>
    db
      .query(
        "INSERT OR IGNORE INTO factory_ask_pushes (ask_id, first_seen_at, pushed_at) VALUES (?, ?, ?)",
      )
      .run(askId, now(), pushedAt).changes > 0;

  const pushedAt = (askId: string) =>
    db
      .query<{ pushed_at: string | null }, [string]>(
        "SELECT pushed_at FROM factory_ask_pushes WHERE ask_id = ?",
      )
      .get(askId)?.pushed_at ?? null;

  const markPushed = (askId: string) => {
    db.query(
      "UPDATE factory_ask_pushes SET pushed_at = ? WHERE ask_id = ? AND pushed_at IS NULL",
    ).run(now(), askId);
  };

  return {
    startBaseline() {
      insert(BASELINE, null);
      return pushedAt(BASELINE) === null;
    },
    completeBaseline: () => markPushed(BASELINE),
    claim(askId, { silent }) {
      if (insert(askId, silent ? now() : null)) return !silent;
      return pushedAt(askId) === null;
    },
    markPushed,
  };
}
