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

  -- Existing hermes memos each ran in their own session (the memo id): one thread per distinct destination_ref,
  -- titled from the first memo's transcript like the adapter does (newlines and tabs flattened; runs of spaces are kept).
  WITH first_memo AS (
    SELECT f.destination_ref AS ref, f.created_at AS created_at,
      trim(replace(replace(replace(COALESCE(f.transcript, ''), char(10), ' '), char(13), ' '), char(9), ' ')) AS text
    FROM memos f
    WHERE f.route = 'hermes' AND f.destination_ref IS NOT NULL
      AND f.seq = (SELECT MIN(x.seq) FROM memos x WHERE x.route = 'hermes' AND x.destination_ref = f.destination_ref)
  )
  INSERT INTO threads (id, kind, title, created_at, updated_at, last_memo_id)
  SELECT ref, 'hermes',
    CASE WHEN length(text) > 60 THEN rtrim(substr(text, 1, 59)) || '…' ELSE text END,
    created_at,
    (SELECT MAX(x.updated_at) FROM memos x WHERE x.route = 'hermes' AND x.destination_ref = first_memo.ref),
    (SELECT x.id FROM memos x WHERE x.route = 'hermes' AND x.destination_ref = first_memo.ref
       ORDER BY x.updated_at DESC, x.seq DESC LIMIT 1)
  FROM first_memo;
  UPDATE memos SET thread_id = destination_ref WHERE route = 'hermes' AND destination_ref IS NOT NULL;
  `,
  // History search: an external-content FTS5 index over the transcript and the summary headline. The content is a
  // view because the headline lives inside `summary_json` (a malformed value indexes as no headline instead of
  // failing the write), which also lets `rebuild` and `integrity-check` read it. Triggers keep the index in step
  // with `memos`; the last statement backfills the memos that exist already.
  `
  CREATE VIEW memo_search AS
    SELECT seq, transcript, CASE WHEN json_valid(summary_json) THEN json_extract(summary_json, '$.headline') END AS headline FROM memos;

  CREATE VIRTUAL TABLE memo_fts USING fts5(
    transcript, headline,
    content = 'memo_search', content_rowid = 'seq',
    tokenize = 'unicode61 remove_diacritics 2'
  );

  CREATE TRIGGER memo_fts_insert AFTER INSERT ON memos BEGIN
    INSERT INTO memo_fts (rowid, transcript, headline)
    VALUES (new.seq, new.transcript, CASE WHEN json_valid(new.summary_json) THEN json_extract(new.summary_json, '$.headline') END);
  END;
  CREATE TRIGGER memo_fts_delete AFTER DELETE ON memos BEGIN
    INSERT INTO memo_fts (memo_fts, rowid, transcript, headline)
    VALUES ('delete', old.seq, old.transcript, CASE WHEN json_valid(old.summary_json) THEN json_extract(old.summary_json, '$.headline') END);
  END;
  CREATE TRIGGER memo_fts_update AFTER UPDATE OF transcript, summary_json ON memos BEGIN
    INSERT INTO memo_fts (memo_fts, rowid, transcript, headline)
    VALUES ('delete', old.seq, old.transcript, CASE WHEN json_valid(old.summary_json) THEN json_extract(old.summary_json, '$.headline') END);
    INSERT INTO memo_fts (rowid, transcript, headline)
    VALUES (new.seq, new.transcript, CASE WHEN json_valid(new.summary_json) THEN json_extract(new.summary_json, '$.headline') END);
  END;

  INSERT INTO memo_fts (memo_fts) VALUES ('rebuild');
  `,
  // Memo flags (swipe actions): done, favorite, archive and soft delete. Times are ISO text like the other time columns.
  `
  ALTER TABLE memos ADD COLUMN done INTEGER NOT NULL DEFAULT 0;
  ALTER TABLE memos ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0;
  ALTER TABLE memos ADD COLUMN archived_at TEXT;
  ALTER TABLE memos ADD COLUMN deleted_at TEXT;
  CREATE INDEX memos_deleted_at ON memos (deleted_at) WHERE deleted_at IS NOT NULL;
  `,
  // Automatic retries of transient step failures: how many tries the step has used (a manual retry deletes the row).
  `
  ALTER TABLE memo_steps ADD COLUMN attempts INTEGER NOT NULL DEFAULT 1;
  `,
];
