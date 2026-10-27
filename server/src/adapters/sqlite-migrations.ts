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
  // Step results live on the memo itself: one row answers "what came out of this memo".
  `
  ALTER TABLE memos ADD COLUMN audio_seconds REAL;
  ALTER TABLE memos ADD COLUMN transcript TEXT;
  ALTER TABLE memos ADD COLUMN route TEXT;
  ALTER TABLE memos ADD COLUMN destination_ref TEXT;
  ALTER TABLE memos ADD COLUMN reply_text TEXT;
  ALTER TABLE memos ADD COLUMN summary_json TEXT;
  `,
  // Registered clients (keyed by the authenticated device name) and per-memo Live Activity tokens.
  `
  CREATE TABLE devices (
    device TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    platform TEXT NOT NULL,
    apns_token TEXT,
    apns_env TEXT,
    push_to_start_token TEXT,
    last_seen_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE TABLE activity_tokens (
    memo_id TEXT PRIMARY KEY REFERENCES memos (id) ON DELETE CASCADE,
    token TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );
  `,
  // The routing decision log: one row per route outcome (and, later, per answer or correction).
  `
  CREATE TABLE route_decisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    memo_id TEXT NOT NULL REFERENCES memos (id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    source TEXT NOT NULL CHECK (source IN ('mode', 'prefix', 'decide', 'default', 'answer', 'correction')),
    destination TEXT,
    tab TEXT,
    confidence REAL,
    model TEXT,
    cost_usd REAL,
    reason TEXT,
    outcome TEXT NOT NULL CHECK (outcome IN ('routed', 'needs_route'))
  );
  CREATE INDEX route_decisions_memo ON route_decisions (memo_id, id);
  `,
  // Threads: a Hermes session that one or more memos ran in. `id` is the Hermes session id.
  `
  CREATE TABLE threads (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('chat', 'hermes')),
    title TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    last_memo_id TEXT
  );
  ALTER TABLE memos ADD COLUMN thread_id TEXT;
  CREATE INDEX memos_thread ON memos (thread_id);
  `,
];
