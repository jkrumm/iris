/** Append-only: a shipped migration is never edited, a schema change is a new entry at the end. */
export const MIGRATIONS: readonly string[] = [
  `
  CREATE TABLE memos (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    id TEXT NOT NULL UNIQUE,
    mode TEXT NOT NULL,
    device TEXT NOT NULL,
    started_at TEXT NOT NULL,
    state TEXT NOT NULL,
    failed_step TEXT,
    error TEXT,
    segment_count INTEGER,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );
  CREATE INDEX memos_state ON memos (state);

  CREATE TABLE segments (
    memo_id TEXT NOT NULL REFERENCES memos (id) ON DELETE CASCADE,
    idx INTEGER NOT NULL,
    bytes INTEGER NOT NULL,
    PRIMARY KEY (memo_id, idx)
  );

  CREATE TABLE memo_steps (
    memo_id TEXT NOT NULL REFERENCES memos (id) ON DELETE CASCADE,
    step TEXT NOT NULL,
    status TEXT NOT NULL,
    started_at TEXT NOT NULL,
    finished_at TEXT,
    error TEXT,
    usage_json TEXT,
    cost_usd REAL,
    PRIMARY KEY (memo_id, step)
  );
  `,
  // Segments become idempotent by content. Rows from before this migration keep an empty sha256.
  `
  ALTER TABLE segments ADD COLUMN sha256 TEXT NOT NULL DEFAULT '';
  ALTER TABLE segments ADD COLUMN received_at TEXT NOT NULL DEFAULT '';
  `,
];
