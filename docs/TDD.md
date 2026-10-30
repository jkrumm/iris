# Iris — Technical Design

Status: v1, 2026-10-27. Companion to [`PRD.md`](PRD.md) (what and why). This
file is how it is built, and it wins over any other doc on design. Research
behind the decisions lives in [`research/`](research/). Public repo: no real
hostnames, IPs, tokens or emails anywhere; use `<domain>`-style placeholders.

## TLDR

Iris has three deliverables in one monorepo:

- **`iris-server`** (Bun + Elysia + SQLite) runs on the mini and owns the memo
  record, every credential and every downstream call.
- **Iris for iOS and Iris for macOS** (SwiftUI, iOS/macOS 26+) are thin
  clients built from shared local Swift packages.

**How a memo flows:**
- **Capture:** the phone records 10 s segments and uploads them while I am
  still talking.
- **Processing:** the server concatenates, transcribes (the agent-workflows
  audio door, Voxtral), routes (spoken prefix, then agent-workflows `decide`), acts
  (journal, herdr or Hermes), summarizes (`triage`) and notifies (APNs: Live
  Activity update plus a rich alert).
- **Tracing:** one trace per memo, keyed by the memo UUID, spans all three
  runtimes.
- **Verification:** agents build, run, screenshot and test both apps on the
  mini through the CLI only (`xcodebuild`, `simctl`, `devicectl`, `xcresulttool`,
  and the `mobilebuildmcp` CLI for UI automation), wrapped in repo skills. No MCP
  servers. Only the
  hardware-bound checks (Lock Screen control, Bluetooth routing, background
  audio) need my hands.

## Decisions

| # | Decision | Why | Rejected |
|-|-|-|-|
| D1 | A server on the mini, not Hermes direct | The phone can reach neither agw (loopback) nor Hermes `:8642` (VPS-only grant, privileged bearer) nor herdr (socket). Credentials stay on the mini | Apps talking to Hermes/Collie directly |
| D2 | Iris owns the memo record; Hermes owns conversations | History must survive a Hermes reset and cover non-Hermes memos. Mirrors Argo | Hermes sessions as the only store |
| D3 | Routing: prefix → `decide` → ask. Three destinations | Hermes's skills already route todos, notes and work. A second full router would pay twice | `decide` on every intent; an LLM router |
| D4 | 10 s segments, uploaded during the take | A crash loses ≤ 10 s, the upload is done at [Stop], and a mic switch is a segment rollover | One file at [Stop] (loses everything on a crash, slow); shorter (request churn) |
| D5 | `AVAudioEngine` tap → `AVAudioFile` (AAC/m4a) per segment; the server decodes and re-encodes on concat | Continuous buffers plus edit lists make the concatenated decode gapless. `AVAudioRecorder` stop/start drops audio | `ffmpeg -c copy` concat (priming gaps); PCM segments (too large on cellular) |
| D6 | APNs via `@parse/node-apn` on Bun `node:http2`, streams capped at 10 | Maintained and pure JS; `apns2` is broken on Bun (undici). Bun ignores `peerMaxConcurrentStreams`, so cap in-flight streams ourselves | `apns2`, the abandoned `apn`, a Go/Swift sidecar |
| D7 | Hand-rolled OTLP JSON telemetry on all three runtimes; clients relay through the server | The estate convention (no SDK on Bun). The ingestion key stays off the devices. opentelemetry-swift's 2026 status is unverified | opentelemetry-swift, Sentry/Embrace |
| D8 | The memo UUID is the trace id (dashes stripped), minted on the client at record start | Phone, server and usage rows join without an extra column; the trace starts at the press | Server-minted ids |
| D9 | JSON fixtures plus JSON Schema in `contracts/` as the API contract, validated by server tests and decoded by IrisKit tests | Catches client/server drift with no code generator in the build | swift-openapi-generator (heavy build plugin for 2 clients) |
| D10 | XcodeGen (`apple/project.yml`), no `.pbxproj` in git | Agents edit YAML, not pbxproj. Alive (2.46.0, 2026-07) | Tuist (monorepo churn, heavier), a committed pbxproj |
| D11 | Local SPM packages under `apple/Packages/` (Core, Capture, UI, Telemetry) | Testable with `swift test` and per-package Swift Testing; IceCubesApp's proven shape | One app target with folders |
| D12 | Native SwiftUI + Liquid Glass with basalt-ui tokens; Textual for markdown; DSWaveformImage for levels | Apple's glass APIs are the premium path, and third-party glass kits aren't ready. `AttributedString(markdown:)` is inline-only | A component kit; swift-markdown-ui (maintenance mode) |
| D13 | iOS/macOS 26.0 minimum; built with Xcode 27.1 (Swift 6.4), Swift 6 language mode, MainActor default isolation for app targets (SE-0466) | iOS 26 has every capture API we need. Xcode 27 matches the CI `xcode-27` image | iOS 27 minimum (excludes nothing useful) |
| D14 | CI: the server on `ubuntu-latest`, Apple on the `xcode-27` hosted label (free on a public repo) | `macos-26` tops out at Xcode 26.6 and one Xcode major per macOS version; parity with the mini's 27.1 | `macos-26` + Xcode 26.6 (toolchain skew) |
| D15 | Distribution through TestFlight internal testing (paid program, enrolling); a free team plus `devicectl` until then | Agents upload from the mini, devices auto-update | Weekly free-team re-sign |
| D17 | CLI-only agent tooling: Apple's CLIs plus the `mobilebuildmcp` CLI (pinned, via `npx`), wrapped in repo skills and Make targets. No MCP server, global or project | The owner doesn't want MCP wired. The CLI exposes the same tools (`ui-automation snapshot-ui/tap/type-text/screenshot`, `simulator`, `device`). `mcpbridge` also needs the Xcode GUI open with the project | `.mcp.json` with MobileBuildMCP; Xcode `mcpbridge` |
| D16 | A public GitHub repo | No secrets in the tree by construction; free macOS CI | Private + self-hosted (no macOS runner there) |

## 1. System context

```
 iPhone (iOS app · IrisWidgets · IrisNotifications) ─┐
                                                     ├─ HTTPS, tailnet ─> iris.mini.<domain> (Caddy) ─> iris-server :7730
 MacBook (Iris for macOS, menu bar) ─────────────────┘                                              │
          ▲                                                                                         ├─> audio door 127.0.0.1:7792  STT · TTS
          └──────────── APNs (alert · liveactivity) <───────────────────────────────────────────────┤
                                                                                                    ├─> agw host 127.0.0.1:7791       decide · triage
                                                                                                    ├─> Hermes :8642 (mini tailnet IP)  sessions
                                                                                                    ├─> herdr socket  snapshot · send_text
                                                                                                    ├─> ~/SourceRoot/brain/Inbox  (brain-sync lock)
                                                                                                    ├─> ~/.iris/data  (SQLite · audio)
                                                                                                    └─> otel.<domain>  OTLP traces + logs
```

- **Network:** `tag:phone → tag:devhost :443` is already granted, so no ACL
  change is needed. The Caddy block `iris.test` becomes
  `iris.mini.<domain>` via `make caddy-tailnet`.
- **Trust boundary:** the tailnet plus a per-device bearer. Nothing is public.

## 2. Repository layout

```
iris/
  AGENTS.md                 the only agent instruction file (dotfiles/docs/agents-md.md)
  Makefile                  check = check-server + check-contracts + check-apple
  contracts/                schema/*.json (JSON Schema) + fixtures/*.json, one pair per endpoint/event
  server/                   Bun + Elysia + bun:sqlite (§3)
  apple/
    project.yml             XcodeGen: Iris (iOS app), IrisWidgets, IrisNotifications, IrisMac
    Packages/
      IrisCore/             models, API client, SSE, contracts decoding, device auth
      IrisCapture/          audio session, route manager, engine tap, segment writer, outbox
      IrisUI/               Theme (basalt tokens), components, Live Activity views, markdown
      IrisTelemetry/        span/log buffer, relay exporter, MetricKit bridge
    Iris/ IrisWidgets/ IrisNotifications/ IrisMac/   thin targets: composition + target-only code
    Tests/UITests/          XCUITest smoke flows
  scripts/                  launch.sh, mini-deploy.sh, send-memo.ts, device helpers
  launchd/                  *.plist.template
  .claude/skills/           repo skills (§10)
  docs/                     PRD, TDD, research/, spikes/, waves/
```

## 3. iris-server

### Modules

The server is a few deep modules behind ports, in email-gateway's style.
`app.ts` is the only place adapters meet ports.

| Module | Owns | Public interface |
|-|-|-|
| `memo/` | The state machine, `MemoStore` (SQLite), the step runner | `createMemo`, `putSegment`, `complete`, `get`, `list`, `retry`, `events` (an async iterator) |
| `pipeline/` | One file per step; each step is a pure function of (memo, ports) | `steps: Record<Step, StepFn>` |
| `routing/` | Prefix parser, the `decide` call, confidence policy; the decision log is written by `MemoStore.completeStep` | `route({memoId, mode, transcript, destinations, herd?, decider?}) → RouteDecision`, `parsePrefix` |
| `devices/` | Device tokens, APNs and push-to-start tokens, Live Activity tokens | `authenticate`, `register`, `tokensFor` |
| `notify/` | Payload building (alert, Live Activity), APNs transport | `Notifier` port |
| `telemetry/` | `otel.ts`, `otel-format.ts`, `log.ts`, `relay.ts` (the client relay) | `withRootSpan`, `withSpan`, `log`, `relay`, `OtlpExporter` |

**Shipped through Wave 11:** `memo/`, `pipeline/` (`steps.ts`), `notify/`, `telemetry/`, `http/`, `adapters/`, `ports/`, `routing/`. The
journal, herdr and hermes destinations are all registered in `compose()`; `devices/` is the `DeviceStore` port plus `adapters/sqlite-devices.ts`; `GET /v1/stats` is the read-only `StatsStore` port plus `adapters/sqlite-stats.ts`. The module and
file map of the code is in `AGENTS.md` §Layout.

Ports, each with a production adapter and an in-memory fake (shipped: `Transcriber`, `Speaker`, `Summarizer`, `Destination` (hermes, journal, herdr),
`Notifier`, `Herd`, `DeviceStore`, `StatsStore` (SQLite only, no fake), `AudioStore`, `AudioCombiner`, `Clock`, `Decider`, `DiagramRenderer` (Pele + resvg-js), `AssetStore` (reply asset files); `Ids` is unused). `Destinations` is the registry
of the registered act adapters (`Partial<Record<"hermes" | "journal" | "herdr", Destination>>`; each is registered by its own env, see §Configuration):
- `Transcriber`
- `Speaker`
- `Decider` (`decide`, adapter `adapters/agw-decider.ts`)
- `Summarizer` (`triage`)
- `Herd`
- `Destination` (journal | herdr | hermes)
- `Notifier`
- `Clock`
- `Ids`

### Memo state machine

```
receiving ──complete──> received ──> transcribed ──> routed ──> acted ──> summarized ──> notified (terminal)
                                          └──> needs_route ──POST /route (answer)──> routed
                                                  ^
                           routed ──act: tab gone──┘
any step ──error──> failed(step)   ──retry(from)──> <step>
acted ──summarize fails for good──> summarized (step row failed, memo not failed) ──> notified
mode transcribe:  received ──> transcribed ──notify──> notified   (no route, act or summarize; never needs_route)
notified (summarize step failed) ──retry(from: summarize)──> acted
```

- **Mode `transcribe` (Wave 17 S2):** the owner picks "just the transcript" up front. The pipeline of such a memo is `ingest`, `transcribe`,
  `notify`: `memo/memo.ts` keeps one transition table and `stepsOf(mode)` / `nextStep({state, mode})` / `advance({..., mode})` /
  `stateBefore({step, mode})` read it per mode, with `notify` running from `transcribed` instead of `summarized`. The steps it does not
  have are absent, not skipped: no `route`/`act`/`summarize` rows on the timeline (`GET /memos/:id` `steps` holds `transcribe` and `notify`;
  the waterfall only draws rows that exist, and Stats keys the two steps under `unrouted`, as it does for any memo without a route), no
  `route_decisions` row, `route`, `reply_text` and `summary` stay NULL, the state is never `needs_route`, and the registered destinations
  are irrelevant (a server with none still finishes the memo; `route()` throws for this mode, which the pipeline never asks). The memo ends in
  the ordinary terminal `notified`, so `isResultReady`, `/result` and `memo.done` need no special case. `notify` announces the transcript clipped
  to a 60-character headline (§12), the alert title is the generic "Iris" (no route chip). A typed memo (`POST /memos/text`, created
  `transcribed` with the text as transcript) in this mode runs only `notify` and ends at once. A `threadId` with this mode is 400
  `bad_request` (a thread continues in Hermes, which this mode never reaches). `POST /retry {from}` is accepted for `transcribe` and `notify`
  only (400 for a step the mode lacks); a failed `notify` resets to `transcribed`.
- **Parking:** only `route` and `act` may park a memo in `needs_route` (a handler result `outcome: "needs_route"`; any other step
  that asks to fails). `act` parks when the herdr tab it was routed to has vanished. The answer is the same `POST /route`, which routes it back
  to `act`.
- **Optional steps (built, Wave 16):** `summarize` is the only one (`OPTIONAL_STEPS`, `memo/memo.ts`). The summary is an extra, so a
  permanent failure of the step (the runner's automatic retries used up, a plain error such as agw `triage` answering with a permanent error such as a 402 or a 502 `INVALID_OUTPUT`, or
  a hermes memo with no summarizer) does not fail the memo: `MemoStore.skipStep` marks the step row `failed` (error and attempts stay, so the
  waterfall shows it failed) and compare-and-sets the memo `acted` → `summarized` in one transaction, with `failed_step` and `error` null.
  `notify` runs next and the memo ends in the ordinary terminal state `notified` (`isResultReady` and `/result`, `memo.done` need no change)
  with `summary` null. `notify` announces the delivered transcript clipped to a 60-character headline instead (not stored; §12). Every other
  step still fails the memo. `POST /retry {from: "summarize"}` is accepted for a `notified` memo whose `summarize` row is `failed` (any other
  `notified` memo stays 409): it resets to `acted` like a failed memo, re-runs summarize and then notify. Notify re-sends: the alert carries the
  memo id as collapse id, so the banner is replaced by the real headline (the Live Activity `end` goes to a token that has already ended, a 410
  that clears nothing the memo needs). Repair of data from before: memos in `failed(summarize)` with a non-empty reply are moved to `notified` by
  `repairFailedSummaries` at boot (no push, step row kept); it first writes `<IRIS_DATA>/iris.db.bak-<timestamp>` with `VACUUM INTO`, only when
  there is something to repair, and is idempotent (repaired memos no longer match). It is a boot repair, not a migration, because a migration
  cannot take a backup first. Delete the backup once production runs cleanly. One-way: a rollback to a build before this change fails summary-less `notified` memos at `notify` if they are driven again.
- **Idempotent steps:** each step is keyed by `(memo_id, step, attempt)`. On
  boot and on every `complete`, the runner drives each non-terminal memo from
  its last finished step.
- **Timeouts:**

  | Step | Timeout |
  |-|-|
  | STT | 300 s |
  | decide | hang guard (30 min) |
  | Hermes | 180 s |
  | triage | hang guard (30 min) |
  | APNs | 10 s |

- **herdr pane queue (built):** deliveries to one pane run one at a time, at most 8 in line per pane (the running one included, `maxPaneQueue`). The ninth fails at once as `unavailable` with `herdr pane <id> queue is full: 8 deliveries already in line`; that is not a `TransientError`, so the step fails after one try (`POST /retry` queues it again) and nothing is typed into the pane.
- **Retries (built):** a transient failure is retried in-process twice, after 2 s and then 8 s (three tries in all; the delays go
  through an injected `Sleep`, so tests never wait), before the step goes `failed`. Adapters mark a transient failure with a
  `TransientError` (`ports/transient.ts`, the one place that classifies: an HTTP 5xx, a timeout or abort, a connection error such as
  ECONNREFUSED / ECONNRESET / `fetch failed`); the runner decides. Everything else (4xx, validation, an off-schema answer, an explicit
  throw) fails at once. A `TransientError` is `before_send` when the request provably never reached the destination (connection
  refused, DNS) and `after_send` otherwise (a timeout, a reset, a 5xx, an unrecognised `fetch failed`: it may have been delivered).

  **A hang guard is not transient.** The 30-minute guard of a model call (the agw host client behind decide and triage, an aborted request) and the
  idle watchdogs (Hermes: no response, or a stream gone idle, within the idle window) mean the downstream is wedged, so a retry would only
  wait out the same window again (~90 minutes for three tries). They throw a plain error (`hangGuardFailure` in `ports/transient.ts`): the step fails after one window and `POST /retry` is the decision. A short request
  timeout that means "try again" (the 30 s Hermes session create) stays transient, as do 5xx and connection errors. The audio-door STT timeout (30 minutes, `timeoutMs` in the adapter) is a hang guard too: one window, then `hangGuardFailure`. The speech timeout (2 minutes) is not retried either: `/speech` is a request, not a step, and answers 503.

  | Step | Retried on |
  |-|-|
  | transcribe, route (decide), summarize, notify | every transient failure |
  | act | `before_send` only: Hermes may already have run the turn after a timeout or 5xx, so those fail and `POST /retry` is the (human) decision |

  `decide` and `triage` are one synchronous request to the agent-workflows host (no submit/poll), so there is no half-created job to guard:
  a 500, a 503 and a network error are transient and retried like any other step; a 400, a 401 and a 502 `INVALID_OUTPUT` (the model failed
  twice) are final. The hang guard aborts the request, which cancels the host's run and the provider call (no `Idempotency-Key`, so the
  host treats a gone client as a cancel; `POST /runs/<id>/cancel` is not used). `stop()` (shutdown) during a backoff cuts the wait short and runs nothing more: the step stays `running`, not `failed`,
  and the next boot's `driveAll` re-runs it from `attempts` 1. Each try bumps
  `memo_steps.attempts`; while the runner waits to retry, the row stays `running` with `error` set to the failure it is retrying
  (clients read `status`, never `error != null`, as failure), and the error clears on success. No `memo.updated` event goes out for a
  retry (the event is per state change); `attempts` shows on the next event or detail fetch. Every try is its own `memo.<step>`
  span (attribute `attempt`) and each wait a `memo.retry_wait` span under the `memo` root, and each retry logs `step.retry`
  (`memo_id`, `step`, `attempt` = the try about to start, `delay_ms`, `error`). `POST /retry` still resets the row, so the re-run
  starts at `attempts` 1.
- **Retention:** audio is deleted 30 days after `notified`; rows are kept.

### Data model (SQLite, WAL, append-only migrations in `server/src/adapters/sqlite-migrations.ts`, `PRAGMA user_version`)

Shipped (Waves 5, 10 and 12). Step results are columns on `memos`, not a separate table.

| Table | Columns (key ones) |
|-|-|
| `memos` | `seq` (autoincrement), `id` (uuid, client-minted), `mode` (auto/journal/hermes/tab/chat/transcribe), `device` (authenticated device name), `state`, `failed_step`, `error`, `started_at`, `segment_count`, `audio_seconds`, `transcript`, `route`, `destination_ref`, `reply_text`, `summary_json`, `thread_id` (the Hermes session the memo belongs to: set by `act`, or at creation for a memo that continues a thread; NULL before then), `done` (0/1), `favorite` (0/1), `archived_at` (nullable ISO), `deleted_at` (nullable ISO; the soft delete), `created_at`, `updated_at` |
| `segments` | `memo_id`, `idx`, `bytes`, `sha256`, `received_at`: PK (`memo_id`, `idx`) |
| `memo_steps` | `memo_id`, `step`, `status`, `started_at`, `finished_at`, `error`, `usage_json`, `cost_usd`, `attempts` (INTEGER NOT NULL DEFAULT 1: tries used, see Retries; on the wire as `attempts` ≥ 1): PK (`memo_id`, `step`); `POST /retry` deletes the rows from the step on, so the re-run counts from 1 |
| `devices` | `device` (PK, the token-map name), `name` (display label), `platform` (ios/macos), `apns_token`, `apns_env` (sandbox/production), `push_to_start_token`, `last_seen_at`, `updated_at` |
| `activity_tokens` | `memo_id` (PK, cascades), `token`, `updated_at` |
| `threads` | `id` (PK, the Hermes session id), `kind` (chat/hermes), `title` (the first ~60 characters of the first transcript, whitespace collapsed), `created_at`, `updated_at`, `last_memo_id`. The destination names the thread in its `Delivery` (`thread: {id, kind, title}`; Hermes: the session id, `chat` or `hermes`, the first ~60 characters of the transcript); `act` persists what it gets, upserting the row and setting `memos.thread_id` in the transaction of `completeStep` (`patch.thread`; `thread_id` is an `act`-owned column). An existing thread keeps its kind and title and moves `updated_at` / `last_memo_id`. A retry from `act` clears `thread_id` when it is the memo's own session (equal to the memo id) until the re-run sets it again, and keeps it for a memo created to continue a thread (its `thread_id` is never its own id: `continuedThread` in `memo.ts`); the thread row stays. The migration backfilled one `hermes` thread per distinct `destination_ref` of an existing hermes memo. `GET /v1/threads` and `/v1/threads/:id` read it (§HTTP API); the queries sit behind the `ThreadStore` port (`adapters/sqlite-threads.ts`, composed into the memo store) |
| `memo_fts` | FTS5 virtual table, external content over the view `memo_search` (`seq`, `transcript`, headline = `summary_json.$.headline`; a malformed `summary_json` indexes as no headline), `content_rowid = seq`, tokenizer `unicode61 remove_diacritics 2`. Triggers on `memos` (insert, delete, update of `transcript` / `summary_json`) keep it in step; migration 7 backfills with `rebuild`. Read by `GET /v1/memos?q` only |
| `reply_assets` | One row per rendered file of a reply's Mermaid blocks (migration 11): `memo_id` (cascades), `id` (uuid, never reused), `block_index`, `format` (svg/png), `scheme` (light/dark), `width`, `height` (points): PK (`memo_id`, `id`). The bytes are files under `<IRIS_DATA>/assets/<memo_id>/<id>`. Rows are written only by the commit of the reply they were rendered for (or the backfill). `memos.reply_assets_failed` (migration 13) marks a reply whose Mermaid blocks all failed to render (§Reply assets) |
| `route_decisions` | `id` (autoincrement), `memo_id` (cascades), `created_at`, `source` (mode/prefix/decide/default/answer/correction), `destination` (nullable), `tab`, `confidence`, `model`, `cost_usd`, `reason`, `outcome` (routed/needs_route), `prefix_words` (nullable; source `prefix`: the leading transcript words the spoken prefix covers). One row per route outcome, written in the transaction of the step's `completeStep`; read with `listRouteDecisions(memoId)`. `answer` (written with the `needs_route` → `routed` move, `memos.route` set in the same transaction) and `correction` (logged after `act`, the memo is untouched) rows come from `POST /v1/memos/:id/route` |

**Indexes.** Besides the keys, `memos(state)`, `memos(thread_id)`, a partial `memos(deleted_at)`, `route_decisions(memo_id, id)`, and (one migration, for the stats reads' `>=` filters) `memos(created_at)` and `memo_steps(started_at)`.

**Memo flags and soft delete (Wave 13).** One append-only migration (the last entry) adds `done`, `favorite` (`INTEGER NOT NULL DEFAULT 0`), `archived_at`
and `deleted_at` (nullable ISO text, like the other time columns) and a partial index on `deleted_at`. None of them touches the state machine or the runner:
a flag is a user annotation, `updated_at` moves with it. `archived_at` is stamped once (archiving an archived memo keeps the first time). A delete is a
**soft delete**: `DELETE` stamps `deleted_at` (allowed in a settled state or `receiving`, never mid-pipeline), the memo stays readable through `GET /memos/:id` (`/audio` and `/speech` are 409 `bad_state` like the other live-only routes) and `POST /restore` clears it, until
`purge_at = deleted_at + PURGE_AFTER_MS` (10 minutes, `memo/memo.ts`, the one definition). The **purger** (`memo/purge.ts`, built from the store, the
audio store, the speech cache and the injected `Clock`) sweeps on boot and every 60 s (`PURGE_SWEEP_MS`): for each memo with `deleted_at <= now -
PURGE_AFTER_MS` it removes the audio files (segments and the combined recording, `AudioStore.remove`), the speech files (`SpeechCache.remove`) and the reply asset files (`AssetStore.removeAll`) first,
then the rows (`MemoStore.purge`: `memos`, which cascades `memo_steps`, `segments`, `route_decisions`, `reply_assets` and `activity_tokens`; the FTS triggers drop the index
entry) and logs `memo.purged` with `memo_id`. Files before rows, so a failed removal (`memo.purge_failed`) leaves the memo for the next pass instead of
orphaning files. A thread whose `last_memo_id` was the purged memo points at its newest remaining memo, and a thread left with no memos is deleted.
The sweep runs behind the shutdown drain (`purger.stop()` / `idle()` next to the runner's). Reads: a soft-deleted memo is in neither `items` nor `pinned` of
`GET /memos`; thread detail leaves it out of `memos` / `messages`, the thread list hides a thread whose memos are all deleted, and a thread's `lastMemoId`
never names a deleted memo (it falls back to the newest live one, null when none). `restore` of a memo past its `purge_at` is 404 even before the sweep got
to it, so a restore never races the file removal. The memo `Memo` domain type carries `done`, `favorite`, `archivedAt`, `deletedAt`; the wire derives
`archived` and `purgeAt` (§HTTP API).

A typed memo (Wave 11) needs no column: it is a `memos` row created in `transcribed` with `transcript` set and `segment_count` NULL, and has no `segments` or ingest/transcribe `memo_steps` rows.

**History search (Wave 12).** `GET /v1/memos?q` runs on SQLite FTS5 (probed on the mini: `bun:sqlite` 1.4.3 ships it), not `LIKE`:
an index answers a prefix search without scanning every transcript, and `unicode61 remove_diacritics 2` folds case and umlauts the way German
text needs ("kalend" finds "Kalender", "ubung" finds "Übung"). The index is external-content over the view `memo_search`, so it stores no second copy
of the text and `rebuild` / `integrity-check` work; triggers keep it in step with `memos`. User input never reaches the MATCH syntax: the text is
split on whitespace, words without a letter or digit are dropped (text with none matches nothing), every remaining term is double-quoted (embedded
quotes doubled) and prefix-matched (`"kalend"*`), terms are ANDed. SQLite's own `changes` counts trigger writes in `bun:sqlite`, so
`createMemo` / `createTextMemo` read `changes > 0`, not `=== 1`, to tell a new row from a conflict.

Planned for R3, not built: `memos.target_tab` / `language` / `route_source`. Device tokens are not stored: the token map lives in `IRIS_DEVICE_TOKENS`.

### HTTP API (`/v1`, bearer = device token; `/health` is public)

Shipped; the authoritative list is `contracts/manifest.json` and the table in `AGENTS.md`.

| Method + path | Purpose |
|-|-|
| `POST /v1/devices/register` | `{name, platform, apnsToken?, apnsEnv?, pushToStartToken?}`; upsert by the authenticated device |
| `POST /v1/telemetry` | The client span/log relay (§8): `{resource: {serviceName: iris-ios\|iris-macos, deviceName, appVersion}, spans, logs, dropped}`. 202 `{accepted: {spans, logs}}`; 413 over 256 KiB; 400 for a schema violation, a timestamp that is not a date, or more than 500 spans and logs together; 503 when the relay is not wired. The records are exported in the background, so an unreachable collector never changes the answer |
| `POST /v1/memos` | `{id, mode, startedAt, threadId?}`, idempotent. `threadId` continues that thread (404 when unknown; see Threads below); a replay naming another thread is 409 |
| `POST /v1/memos/text` | `{id, mode, startedAt, text, threadId?}`: a typed memo. `text` is trimmed, 1 to 20 000 characters, counted as Unicode code points (else 400). A missing or unknown `mode` is 400. Created directly in `transcribed` with `transcript = text` and driven from `route`: 202 + memo, on a replay too. Idempotent by id: the same body returns the memo, another body (a different `threadId` included), another device or a recorded memo with that id is 409 `conflict`; an unknown `threadId` is 404 |
| `PUT /v1/memos/:id/segments/:n` | Raw m4a bytes, idempotent by `n` (same sha → 200, different → 409) |
| `POST /v1/memos/:id/complete` | `{segmentCount}`. A 422 lists the missing indices |
| `PUT /v1/memos/:id/activity-token` | The Live Activity push token for this memo (204) |
| `POST /v1/memos/:id/retry` | `{from: Step}`, only for a `failed` memo, or `from: "summarize"` on a `notified` memo whose summarize step failed (§Memo state machine, Optional steps); 400 `bad_request` for `from: "transcribe"` on a typed memo and for a step the memo's mode lacks (mode `transcribe`) |
| `POST /v1/memos/:id/route` | `{destination: hermes\|journal\|herdr, tab?}` (`tab` iff herdr). `needs_route`: the destination must be registered (else 400 "<dest> not available"); writes an `answer` decision, moves the memo to `routed` (compare-and-set) and drives it on: 202 + memo. After `act` (`acted`/`summarized`/`notified`): records a `correction` decision, no re-act, memo unchanged: 200. Any other state 409 `bad_state`, so a second answer while the first drives is a 409. A memo in mode `transcribe` has no route to answer or correct: 400 `bad_request`, before the state is looked at, so no decision row is ever written for it |
| `GET /v1/memos?limit&cursor&q&route&state&favorite&archived&kind` | History, paged, newest first: `{items, pinned, pinnedTruncated, nextCursor}`. `q` (≤ 200 characters) searches transcript and summary headline (see Data model); `route` (hermes\|journal\|herdr) and `state` (any memo state) filter exactly; `favorite=true` keeps the favorites, `archived=true` lists **only** archived memos (without it archived memos are hidden), `kind=chat\|hermes` keeps the memos whose thread has that kind (the Chats chip); `favorite` and `archived` accept only `true` (omit them to switch off); all combine, an unknown value is 400. Soft-deleted memos are never listed or pinned. `items` never holds an **open** `needs_route` memo (one with `done` false), so the seq cursor stays stable when one leaves that state; the first page (no `cursor`) instead carries `pinned`: every open `needs_route` memo matching the filters, newest first, at most 50. `pinned` is always present, `[]` on later pages. `pinnedTruncated` is always present too: `true` on the first page when more than 50 open `needs_route` memos match (the oldest are left out of `pinned`), `false` otherwise and on every later page. `state=needs_route` answers from `pinned` plus, paged in `items`, the `done` ones. A `done` `needs_route` memo is no longer an open question: it is not pinned and sits in `items` at its seq position (the client dims it); marking one done after page 1 is the same case as answering it, so the de-duplication rule below covers it. `pinned` is not paged: the 50 cap is deliberate (a parked memo is an open question for the user, not an archive), `pinnedTruncated` is how a client learns the cap bit, and a `cursor` always yields `pinned: []`. Clients that read only `items` no longer see parked memos in the default list. A memo answered after page 1 leaves `needs_route` and appears in `items` at its seq position, so a later page can repeat a memo already in `pinned`: clients de-duplicate by memo id across `pinned` and every page (pinned first, then items whose id is not present yet) |
| `GET /v1/memos/:id` | Memo + step timeline. Also a soft-deleted memo (with `deletedAt` / `purgeAt`, so undo works); 404 after the purge |
| `PATCH /v1/memos/:id` | `{done?, favorite?, archived?}`: booleans, at least one; an empty body, an unknown key or a non-boolean is 400 (the route rejects unknown keys itself, Elysia strips them before validation). 200 memo; 404 unknown; 409 `bad_state` on a soft-deleted memo. Allowed in every pipeline state. Publishes `memo.updated` |
| `DELETE /v1/memos/:id` | Soft delete: 200 memo with `deletedAt` and `purgeAt`. Only settled memos (`notified`, `failed`, `needs_route`) and a memo still `receiving` (a cancelled take: the client creates the memo at its first closed segment), else 409 `bad_state`. A deleted `receiving` memo takes no more segments and no `complete` (both 409 `bad_state`, like every write to a deleted memo), so the pipeline never starts; a segment write still in flight when the delete lands is refused and its file removed right after the write (no row names it; the segments already recorded stay for a restore within the undo window), the purger removes the rest. A repeat is idempotent (200, the first `deletedAt`, no event); 404 unknown. `retry` and `route` on a deleted memo are 409 `bad_state`. Publishes `memo.updated` |
| `POST /v1/memos/:id/restore` | Undo: 200 memo (`deletedAt` cleared, flags kept); 409 `bad_state` when the memo is not deleted; 404 once it is purged or past `purgeAt`. Publishes `memo.updated` |
| `GET /v1/memos/:id/result?wait=<s>` | Long-poll until result-ready (≤ 600 s) |
| `GET /v1/threads?kind=chat\|hermes&limit&cursor` | `{items: Thread[], nextCursor}`, newest `updatedAt` first; `Thread = {id, kind, title, createdAt, updatedAt, lastMemoId}`. The cursor is the last row's `(updated_at, id)`, so it stays valid as threads are added or updated. A malformed cursor or unknown `kind` is 400 |
| `GET /v1/threads/:id` | `{thread, memos, messages}`: the memos that ran in the thread (oldest first) and the conversation built from them, `messages: [{memoId, role: user\|assistant, content (markdown), createdAt}]`: per memo its `transcript` (`user`, dated by the memo's `createdAt`) and its `reply_text` (`assistant`, dated by the end of its `act` step; omitted while empty). Iris's own record: Hermes is not consulted, so the response never depends on it. Read in a fixed number of queries (the thread, its memos, the `act` finish times), however long the thread is. Unknown thread 404 |
| `GET /v1/memos/:id/audio` | The concatenated audio for the scrubber (`Range`); 409 `bad_state` for a soft-deleted memo |
| `GET /v1/memos/:id/speech` | TTS of the speech-ready variant of the answer (below), cached as an mp3; 409 `bad_state` for a soft-deleted memo |
| `GET /v1/memos/:id/assets/:assetId` | One rendered file of a reply's Mermaid block (ids from the memo's `replyBlocks`): `image/svg+xml` (with `content-security-policy: default-src 'none'; style-src 'unsafe-inline'`) or `image/png`, `cache-control: private, max-age=31536000, immutable` (an id is never reused), `x-content-type-options: nosniff`; 404 for an unknown memo or asset, 409 `bad_state` for a soft-deleted memo, 503 without media |
| `GET /v1/events` | SSE: `ready`, `memo.updated`, `memo.done` (for the Mac and the foreground iOS app) |
| `GET /v1/herd` | herdr tabs `{id, repo, label, agentState, lastActivity}` (snapshot; `lastActivity` is always null) |
| `GET /v1/stats?days=<n>` | `days` 1..365, default 30, else 400 `bad_request`. `{days, from, to, perDay: [{date, route, count}], perWeek: [{weekStart, count}], stepMedians: [{step, route, medianMs, samples}], costPerRoute: [{route, costUsd, memos}]}`. Read-only aggregates over `memos` (by `created_at`) and `memo_steps` (both filter columns are indexed); no table of its own, no spend; 503 when the app is composed without a `StatsStore`. The window is the last `days` **local days of the server** (today included, `from`/`to` are `YYYY-MM-DD`); `date` and Monday-start `weekStart` use the same zone, and the first week only counts the days inside the window. A null `route` is reported as `unrouted`. `stepMedians` is the baseline of the memo detail waterfall's faster/slower hint, **per step and route** (a step's speed depends on where the memo went): `done` step records whose `started_at` is in the window, grouped by step and the memo's route (`unrouted` as above), in pipeline order then route (integer ms; even counts average the two middle values and round, no other interpolation; a pair without samples is absent). `samples` is the n behind each median. **The client owns the minimum-n threshold**, the server does not send a `minSamples`: the threshold is a presentation choice (a hint wants more evidence than a plain number, and it may differ per surface), changing it must not need a server deploy or a contract change, and the server stays a plain aggregate that reports n honestly. `costPerRoute` sums `memo_steps.cost_usd` per route (routing-decision spend is on the `route` step row), `memos` counts the memos once. The memo detail waterfall compares its step durations to `stepMedians`. Day bucketing and medians run in the adapter, not with SQLite's `localtime`, so the window and the days share the process time zone |

A separate route rather than a `text` field on `POST /v1/memos`: that route answers 201/200 for a memo that is still `receiving` and waits for segments, a typed memo is complete on arrival and its replay must compare a body, so sharing the handler would branch every line of it. A typed memo has no ingest or transcribe row in its timeline. The memo shape carries `typed: true` for a typed memo and omits it for a recording (one predicate, `isTyped` in `memo.ts`: past `receiving` with no segment count; `GET /memos/:id` reports `segmentCount` 0 there, so clients read `typed`). `POST /retry` from `transcribe` on a typed memo is 400: the text is its only transcript. `GET /audio` on a typed memo is 409 `bad_state` (no recording); `/speech` works as for any memo.

The memo shape always carries `done`, `favorite` and `archived` (booleans; `archived` is `archived_at IS NOT NULL`, the time stays server-side) and, only while the
memo is soft-deleted, `deletedAt` and `purgeAt` (ISO, 10 minutes apart); both are omitted, never null, otherwise. A flag change, a delete and a restore
publish the existing `memo.updated` SSE event (same payload: `id`, current `state`, `step: null`); the client refetches the memo. The event is internally
marked `flagChange` (not on the wire): `GET /events` does not follow it with `memo.done`, and the needs-route alert and Live Activity bindings ignore it, so a
swipe never re-fires a notification or a result-ready handler.

While a memo is `needs_route`, the memo shape carries `routeReason` (the latest decision's reason) and, on a low-confidence park, `routeSuggestion` (the model's best guess); both are omitted, never null, in every other state.

**Threads.** A thread is a Hermes session (`threads` row, `kind` `chat` for a chat, else `hermes`). `threadId` on either create route continues one: the service answers 404 for an unknown thread, 409 `destination_unavailable` while Hermes is not registered (the turn could only fail at route, so create refuses it and stores nothing; a replay of an existing memo is judged by its stored thread instead) and 409 `conflict` for a replay whose `threadId` differs (`continuedThread`: a memo's own session, equal to its id, is not a continuation). The memo is stored with that `thread_id`. The route step forces it to `hermes` (decision source `mode`, no decider call, whatever the mode or a spoken prefix says; Hermes is registered by then, create refused the turn otherwise), and `act` delivers into the thread's session (`Destination.deliver({threadId})`: the Hermes adapter skips the session create), one turn at a time per thread (a keyed queue in the `act` handler: a second memo for the same thread waits for the first turn's reply instead of failing; different threads do not wait for each other. The wait is bounded at 30 minutes, the size of a hang guard, since a turn has an idle watchdog but no wall-clock cap: past it `act` fails with `KeyedQueueTimeout` (`thread <id> is busy: waited 1800000 ms behind memo <id>, which has not finished`) and the task never runs, `POST /retry` queues it again. The line stays consistent: the failed waiter keeps its place until the stuck turn ends, so a later memo still waits for that turn, and the stuck turn's eventual completion changes nothing for anyone. A turn that has started is never cut off. `memo/keyed-queue.ts` takes `maxWaitMs` and an injected cancellable sleep (the timer is cleared as soon as the turn ahead finishes, so a served waiter leaves nothing pending); herdr's per-pane queue leaves it off, its calls are bounded by their own 5 s timeouts, but it takes a `maxDepth`, see the herdr pane queue bullet above). A waiter parked on that queue does not hold a `driveAll` slot: the act handler passes the runner's `whileWaiting` to the queue, which wraps only the wait behind another turn (a turn that starts at once never calls it); the runner gives the memo's slot back for that wait and takes one again, queueing behind whoever holds it, before the waiter delivers, so `driveAll` still runs at most three memos at once and an unrelated memo is never stuck behind a parked thread. Drives outside `driveAll` (HTTP create, retry) hold no slot, so `whileWaiting` is a plain await there with `chat` taken from the thread's kind, not the memo's mode, so every turn of a chat thread re-sends the no-side-effects `system_message`. The upsert moves the thread's `updated_at` and `last_memo_id` as for any `act`. The conversation is Iris's own data (`threadMessages` in `memo.ts`, built from the thread's memos in `seq` order); Hermes keeps its session but its transcript is never read, and a chat is tagged by `threads.kind`, not by Hermes's `source`.

**Planned, not built:** the `targetTab` / `language`
fields of `POST /v1/memos`.

Every request and response body has a schema and a fixture in `contracts/`.
Elysia routes declare TypeBox schemas, and `make check-contracts` asserts that
the exported JSON Schema matches `contracts/schema`.

### Pipeline steps

Shipped as five runner steps: `transcribe` (includes the concat below), `route`, `act`, `summarize`, `notify`. The journal and herdr
destinations are registered by `compose()` from `BRAIN_DIR` and `HERDR_SOCKET`. The timeouts follow `agent-limits.md`
(idle watchdogs and 30-minute hang guards, not the budgets sketched earlier). Transient failures are retried automatically (§Memo state
machine, Retries); retention (audio deleted 30 days after `notified`) is not built. Recover a `failed` memo with `POST /retry`.

1. **concat:** `ffmpeg -f concat` over the segments → decode → mono 16 kHz
   AAC. Records `audio_seconds`.
2. **transcribe:** `POST <audio door>/audio/transcriptions` (`AUDIO_DOOR_URL` carries the `/v1`).
   - Fields: `model=voxtral-mini-transcribe-3-0`, `language` (the device hint or
     auto), and `context_bias` (repo names, live tab labels, recent thread
     titles).
   - Header: `Authorization: Bearer <AUDIO_DOOR_TOKEN>`; the answer carries `agw-run-id`, logged and set on the span as `agw.run_id`. A 401 is final.
   - The door handles chunking up to about 2 h. A 413 is terminal.
3. **route:** only destinations with a registered act adapter are choices (`Destinations`). Mode `transcribe` never reaches this step (§Memo state machine).
   - If the memo's mode is not auto, it wins (`journal` → journal, `hermes` → hermes, `tab` → herdr, `chat` → hermes). Source `mode`; a chat memo is never routed elsewhere by prefix or `decide`. Mode `tab` carries no name:
     it routes to the only live tab, and parks with "which tab?" when there are several or none.
   - Otherwise the prefix parser matches "journal|tagebuch", "an hermes|hermes", "tab <name>", case- and diacritic-insensitive, with the
     phrase starting within the first 6 words. Everything up to and including the phrase, plus trailing punctuation, is
     cut from the text `act` and `summarize` receive (`deliveredTranscript`, derived from the raw transcript whenever a `prefix` decision exists;
     kept whole when nothing else was said). `memos.transcript` stays the raw speech-to-text, so a retry from `route` routes the same way. Source `prefix`.
   - **Multi-word tab names:** after "tab" the parser reads up to 5 words (none empty, none past one that ends in punctuation) and, given the live tab and repo labels, takes the longest run that equals a label, comparing folded with punctuation as a space (spoken "iris server ops" = label `iris-server-ops`); no match leaves the first word alone. A label that only shares its first words never matches ("tab iris server" does not name `iris-server-ops`). The decision row records `prefix_words`, the count of leading transcript words the prefix covers (words before the phrase included), and `deliveredTranscript` cuts exactly that many words, because the herd that told where the name ended is not there on a retry or at `act`; a row without a count (older rows, the act-time park row) falls back to parsing again. No wire change: the count is not in any response.
   - **Spoken tab resolution:** a spoken tab name is resolved against the live `Herd` to a tab id, which is what the decision stores. It matches
     a tab label or a workspace (repo) label, ignoring case and diacritics. Exactly one match routes; none or several park with a
     reason that names the spoken name (`no tab named "x"`, `several tabs match "x"`); a herd that cannot be read parks as "herd unavailable".
     Every park of this kind carries `destination: herdr`.
   - A mode or prefix that names an unregistered destination parks at `needs_route` with the reason "<destination> not available".
   - With fewer than two registered destinations the step stops here: it routes to the only one (source `default`, confidence 1, no spend). When that
     one is herdr it needs a tab like mode `tab` does: the only live tab, else a park with "which tab?" (or "herd unavailable").
   - Otherwise call `decide` through the `Decider` port (agw host `POST /decide`, hang guard like `triage`) with state = transcript (first 4k chars) + one line
     per live tab, and questions `destination: choice[<registered>]`, plus `tab: choice[...]` when herdr is registered and there are live
     tabs. A failing `Herd` call omits the tab lines and the question. Source `decide`.
   - At confidence ≥ 0.8 → `routed` (for herdr the weaker of destination and tab confidence, and a live tab is required); otherwise
     `needs_route` with the model's best guess recorded as the decision's destination. A refusal, an unknown choice, herdr without a live tab
     and a missing decider ("decide unavailable") park the same way. An infrastructure failure of the call (transport error, hang guard,
     off-schema answer) throws instead: the step fails and `POST /retry {from: route}` recovers it.
   - Every outcome is written to `route_decisions`; the step row records the `decide` cost and usage (`costUsd` null stays null, never 0), and the log
     line and span of the call carry the host's `agw.run_id`.
   - **decide's model (S4, 2026-10-29):** the host's `decide` runs `decision-1-eu` (off Requesty; the answer's `model` reads `microsoft-decision-1`). A live probe through
     `route()` and the real adapter, journal / hermes / herdr registered with two live tabs, bounded by `timeout`: journal 0.9996 and 0.9998, hermes 0.9940 and
     0.9997, herdr 0.985 (tab `iris / server` picked) and 0.985 (tab `dotfiles / claude` picked), a vague "mach mal das Ding fertig" 0.30 (parked at `needs_route`).
     Every clear case routes far above 0.8 and the ambiguous one falls far under it, so the 0.8 threshold stays. Span attributes `route`,
     `route.source`, `route.confidence`; log `route.decided`.
4. **act:** dispatches on `memo.route`; a route without a registered destination fails the step. For `herdr` the tab comes from the latest
   routed decision (`store.listRouteDecisions`, not a `correction`) and is passed to `Destination.deliver` as `tab`; a herdr route without one
   parks the memo (reason "which tab?"). A `TabGoneError` from the destination parks it instead of failing it too. Either way `act` returns
   `needs_route` with a decision row (outcome `needs_route`, destination `herdr`, the tab or null, the reason, the source of the decision that
   routed it), and the answer re-runs `act`. Any other delivery failure fails the step as before.

   | Destination | Action |
   |-|-|
   | journal | Write `brain/Inbox/<YYYY-MM-DD>-<slug>.md` (frontmatter `title`, `date`, `tags: [journal, iris]`, `source: iris`, `memo`) under the brain-sync lock (`brain/docs/brain-access.md`), then commit and push following that doc |
   | herdr | `pane.send_text` (the transcript) + `pane.send_keys ["enter"]` on the tab's agent pane over the herdr socket (the pane comes from `session.snapshot`: the tab's agent, else its only pane). A tab missing from the snapshot, or a `pane_not_found` answer to either write (the tab closed in between), is `TabGoneError`, which leads to `needs_route`. Deliveries to one pane are serialised in the adapter, so text and Enter of two memos never interleave. `ref` is the tab id, `reply_text` stays empty |
   | hermes | `POST /api/sessions {id: memoId, source: "iris"}` (201/409 = OK) → `POST /api/sessions/:id/chat/stream {message}`. Collect the final assistant text from the SSE, store it as `reply_text`, and upsert `threads` (kind `hermes`) |
   | hermes, mode `chat` | The same, with `source: "iris-chat"` and `system_message` on every `chat/stream` turn: answer conversationally and take no action with side effects (no tool call that writes, sends, schedules or changes anything). Thread kind `chat`. `system_message` is Hermes' per-turn ephemeral system prompt: appended to that turn's prompt, never stored, so a later turn in the same session must send it again |

   **Hermes rewrites unknown session sources.** `_normalize_session_source` in Hermes' `api_server` keeps only its own allow-list (`api_server`, `browser`, `cli`, `telegram`, `discord`, `slack`, `desktop`, `dashboard`) and maps anything else to `api_server`. Both `iris` and `iris-chat` are therefore stored as `api_server` on the Hermes side: a chat is not visible there. `threads.kind` in Iris's own database is the marker. The values are still sent, which works unchanged if Hermes widens its list.

   **Continuing a thread** (shipped, see Threads under the HTTP API): `Destination.deliver` takes `threadId`; the Hermes adapter then uses that session as it is (no `POST /api/sessions`) and goes straight to `chat/stream`.
5. **summarize:** agw host `POST /triage {destination, transcript, reply?}` (raw fields, sent whole; the host cuts each at 4000 characters and owns the prompt) answering the flat
   `{headline (≤60), detail (≤240), spoken (≤300 characters, the cap standing for two sentences), model, attempts, latencyMs, usage}`. Journal and herdr skip the model
   and use templates (no spend, no summarizer needed): headline "Saved to journal" / "Sent to <repo> / <label>" (≤60; "Sent to tab" when the
   herd no longer lists the tab), detail the whitespace-collapsed transcript excerpt (≤240), spoken one sentence. Hermes keeps the model and
   fails the step without a summarizer; the step is optional (§Memo state machine, Optional steps), so the memo goes on to `notify` with
   `summary` null and `/health` keeps listing `summarize` in `degraded` while no summarizer is configured.
6. **notify:** (without a summary: headline = the delivered transcript, whitespace collapsed, clipped to 60 characters; the alert body and
   the Live Activity `end` use it, `spoken` is empty)
   - a Live Activity `update` (priority 5) for each phase change, plus a final
     `end` with the result content state and `dismissal-date` = now + 15 min;
   - one alert (priority 10, `mutable-content: 1`, `category: MEMO_DONE` or
     `MEMO_NEEDS_ROUTE`, `thread-id: memo`, a `memo` id in the custom payload). `MEMO_NEEDS_ROUTE` ships: sent
     best-effort when a memo enters `needs_route` (generic title plus the park reason, never transcript or reply),
     alert only, since the Live Activity `needsRoute` update comes from the phase binding. Both alerts share the
     collapse id (the memo id), so the done alert replaces the needs-route banner;
   - SSE `memo.done`;
   - a `log` stand-in when APNs is not configured.

**Speech-ready variant** (`memo/speech-text.ts`, a pure function; no stored column, no migration, no wire change). `MemoMedia.speech` derives it on
every `GET /v1/memos/:id/speech` from `replyText` and `summary.spoken`, so a retry that changes the reply changes the variant, and the text-keyed
speech cache (and the single-flight key) re-synthesizes exactly then; a changed reply whose variant is unchanged hits the cache. It is the only
synthesis path, so [Play] and spoken replies share it.
- **Cleaning:** fenced code blocks become "a code block", Mermaid/PlantUML/DOT/D2 fences "a diagram", tables "a table with N rows" (data rows);
  images keep their alt text, links their text, bare URLs, autolinks and reference definitions go; headings, emphasis, strikethrough, quotes,
  list markers, task boxes, escapes, inline-code ticks and inline HTML are removed. Headings and list items get a full stop so the voice pauses.
- **Language:** the summary phrases ("ein Codeblock", "Details auf dem Bildschirm.") follow the language of the reply, found by counting German
  versus English function words outside code and URLs; German on a tie, since the transcripts are mostly German.
- **Threshold:** a cleaned reply up to `SPEECH_MAX_CHARS` = 600 characters (about 40 s aloud) is spoken whole. Longer, the variant is
  `summary.spoken` + "Details on screen." (the first whole sentences of the cleaned reply when there is no summary, e.g. summarize failed). Measured on the cleaned
  text, so a long code block does not push a short answer past it. Without a reply the (cleaned) `summary.spoken` is spoken. A notified memo
  with a reply and no summary is therefore speakable (`/speech` is 409 only when there is neither).

### Reply assets: Mermaid blocks rendered by Pele (Wave 14)

When `act` has the reply, `ReplyAssets.sync` (`memo/reply-assets.ts`, the one call `createStepHandlers` makes, right after the delivery) makes the memo's
stored assets match `replyText`. `extractMermaidBlocks` reads the top-level fenced blocks the way CommonMark does (backtick or tilde fences, closing fence
of the same character and at least the same length, an unclosed fence runs to the end, a fence nested in another fenced block is that block's text) and
keeps those whose info string starts with `mermaid`; **`index` is the block's position among the reply's mermaid fences, from zero**, so the client
matches the i-th mermaid fence of its markdown to `replyBlocks[index]`. At most 12 blocks are rendered per reply, the rest stay code blocks (`reply.blocks_capped` with `total` and `cap`).

Each block goes through the `DiagramRenderer` port once and yields, for **light and dark**, an SVG (a standalone document with the scheme's colours resolved, no
CSS variables left) and a PNG, so four files per block (`svg|png` × `light|dark`) stored through `AssetStore` under fresh uuids; the rows are replaced in
one transaction at the commit of the reply (`completeStep`, below), then `AssetStore.prune` deletes every file that is no longer referenced. A retry whose reply differs
therefore re-renders and leaves no old file behind; a retry from `act` (or earlier) drops the rows at once (`resetForRetry`). **A block that cannot be rendered
or stored stays a code block**: no asset, the step succeeds. Pele rejecting the diagram logs `reply.render_failed` (`memo_id`, `block`, `error`); a failing `AssetStore.put` logs `reply.store_failed`
and removes that block's files. A pass that fails as a whole (the database) logs `reply.assets_failed`, removes the files it wrote (the rows, and so the earlier reply's assets, are untouched) and leaves the reply as it was; `sync` never throws. Passes of one memo are serialized (`createKeyedQueue`), a pass yields to the event loop between
blocks (Pele and resvg are synchronous CPU), and files stored for a memo that was purged meanwhile are removed.

**Commit with the reply (Wave 16).** `sync` runs inside the `act` handler, before `completeStep` commits `reply_text`, so it only *stages*: it renders and stores the files, then hands the
store `MemoStore.stageReplyAssets(id, {replyText, assets, failed, onSettled})`, which keeps the latest staging per memo in process memory and writes **no row**. Until the commit nothing is
on the wire (`replyBlocks`, `GET /memos/:id/assets/:assetId`) and the earlier reply keeps its rows and files. `completeStep` settles it in its own transaction: a patch whose `replyText` equals the staged one that
**wins** deletes the memo's rows, inserts the staged ones and writes the failed marker (below); a winning patch with any other reply text deletes the rows (they describe a reply that is gone) and clears the marker.
A patch that **loses its compare-and-set** changes nothing, so the rows and files of the earlier committed reply stay intact. After the transaction `onSettled` runs inside the memo's queue: `"committed"` prunes
the memo's files down to the rows (the earlier reply's files go), `"discarded"` removes only the files of that attempt by id (`reply.assets_discarded`). A `completeStep` whose transaction throws rolls back and settles the matching staging as discarded before the error propagates. A newer staging settles the older one as discarded;
`resetForRetry` from `act` discards the staging and clears rows and marker; the purge forgets it. Rows are not written at `sync` because they would be visible for the window before the commit and a lost CAS would
have to delete rows that may belong to the earlier reply; staging in memory instead of carrying the assets in `MemoPatch` keeps the runner and the handler contract unchanged. The staging is process memory: after a crash the re-run `act`
re-renders and its prune removes the leftovers.
The purge removes the files first (`AssetStore.removeAll`), the cascade the rows.

**Backfill.** Replies from before Wave 14, or whose render was lost, get assets from `ReplyAssets.backfill`, run once per start from `index.ts` (never blocks listen). Shutdown calls `ReplyAssets.stop()` before awaiting `idle()`: the sweep ends after the memo it is on, so it never holds the drain.

**Orphan sweep.** A crash between a commit and its prune (or between a render and its staging) leaves files that no row names. `ReplyAssets.sweep`, started next to the backfill in `index.ts`, lists the memo directories under `<IRIS_DATA>/assets/` (newest change first, at most `SWEEP_LIMIT` = 200 per start) and, per directory and inside the memo's queue, removes every file that is not named by the memo's rows and not held by an in-flight attempt (files staged with the store and not yet settled). A directory whose memo no longer exists is swept empty. It logs `reply.orphans_removed` (memo id, count, file names) and `reply.sweep` (examined, removed), skips a directory that fails (`reply.sweep_failed`) and stops after the current memo on `stop()`.
It reads live memos whose `reply_text` mentions mermaid, that have no `reply_assets` rows and no failed marker, newest first (`MemoStore.listReplyAssetCandidates`), keeps those with a real top-level fence
and takes at most `BACKFILL_LIMIT` (50) of them; each goes through the memo's own queue, re-reads the memo there and stores through `attachReplyAssets`, which only writes when the memo is live, its
`reply_text` is still the one rendered and it still has no rows (a retry or deletion in between wins; the files are removed). Idempotent: a memo with assets is no candidate, so a second run renders nothing.
A boot sweep rather than a `make` target because it runs in the one process that owns the database, the per-memo queue and the asset directory (no second writer on the mini's live service, no extra deploy step);
a memo whose blocks the renderer all refused carries a **failed marker** (`memos.reply_assets_failed`, migration 13), so it is no candidate on the next start: the `act` pass sets it with the commit (`failed` in the staging: the reply
has fences and Pele refused every one; logged as `reply.assets_marked_failed`), the backfill sets it through `markReplyAssetsFailed` (only while `reply_text` is still the one it rendered). A commit that carries a reply (any `replyText`) and `resetForRetry` from `act` clear it, so a changed reply is tried again.
A reply where only some blocks failed has rows and is no candidate either way. A block that rendered but could not be stored (`reply.store_failed`, a full disk) is not a refusal: it never marks, so the memo stays a candidate for the next start. A marked memo renders again through `POST /retry {from: act}`.

Wire (additive, `contracts/`): `Memo.replyBlocks` (memo detail, list, thread detail memos and every other memo body; **omitted** when no block rendered, never
`null` or empty) is `[{index, kind: "mermaid", width, height, svg: {light, dark}, png: {light, dark}}]` with asset ids; `width` and `height` are points, the
PNG is drawn at 2x (`PNG_SCALE`), shrunk so the long edge stays ≤ 4096 px. The file is `GET /v1/memos/:id/assets/:assetId`. A block that failed leaves a gap in `index`. The memo
read model assembles the blocks in `MEMO_SELECT` (one `json_group_array` subselect over `reply_assets`), a block missing one of its four files is dropped.

**Pele and the rasterizer (decision, 2026-10-28).** Pele (`obsidianmd/pele`, npm `pele`, MIT, TypeScript, synchronous `render(text) → {svg, width, height}`, no runtime
dependencies, no DOM needed, Mermaid 12.1 syntax, colours and fonts through `--pele-*` CSS variables; errors are `PeleError` with `code` `syntax | unsupported-diagram | semantic | limit`)
runs unchanged under Bun. It is young (first release 2026-10-06, a release every few days): **pinned to 1.10.0**, the newest version past the repo's 3-day
release cooldown on the day of the decision (1.11 and 1.12 were younger), and bumped on purpose. The rasterizer is **`@resvg/resvg-js` 2.6.2** (MPL-2.0 used as a dependency, N-API prebuilt binaries for macOS arm64/x64 and Linux, loads and
runs under Bun, synchronous render, no headless browser; the Rust `resvg` core is active, the npm wrapper's last stable is 2.6.2 and a 2.7 alpha is out). The alternatives (`@resvg/resvg-wasm`: same engine and version; `sharp`: librsvg inside a general image library; `@napi-rs/canvas`: a canvas, not an SVG renderer) were compared on registry metadata only, not benchmarked:
resvg-js is the one purpose-built SVG rasterizer with prebuilt binaries and it worked first try. The
decisive probe: resvg ignores CSS `var()`, so a Pele SVG rasterized as is came out black. The adapter (`adapters/diagram-pele.ts`) therefore sets the scheme's
`--pele-*` on the root element and substitutes every `var()` (root declarations, else the fallback) before it serves or rasterizes the SVG: the SVG assets are
portable as well (any viewer, no CSS engine needed). Colours are the basalt tokens (`docs/design/mockups/tokens.css`: panel as background, ink as foreground,
accent and the status colours as the chart series); the text is set in `-apple-system, Helvetica Neue, Helvetica, Arial, sans-serif`, and resvg draws it with the macOS Helvetica files, named explicitly: with `loadSystemFonts` resvg scans every system font on each render, which cost
250-460 ms per PNG on the mini against about 4 ms with `fontFiles` (a whole block renders in ~30 ms). A host without those files falls back to the scan. The PNG gets an opaque background (the scheme's panel colour).
The research gateway was down for this item (503), so the facts above come from the npm registry, the GitHub repository, Pele's published type declarations and probes run under Bun.

### Downstream facts (re-verify when touching an adapter)

| Downstream | Contract | Where it is documented |
|-|-|-|
| Pele | npm `pele` 1.10.0 (MIT), `render(text, {fontFamily}) → {svg, width, height}` sync, throws `PeleError`; theme = `--pele-bg/fg/muted/line/surface/surface-alt/border/accent/critical/error/font` and `--pele-series-1..8` on the root `<svg>` | https://pele.run, `node_modules/pele/dist/*.d.ts` |
| resvg-js | `@resvg/resvg-js` 2.6.2: `new Resvg(svg, {background, fitTo: {mode: "zoom", value}, font: {loadSystemFonts, defaultFontFamily}}).render().asPng()`; no CSS `var()` support, so the SVG is resolved first | https://github.com/thx/resvg-js |
| audio door | agent-workflows `audio` process, `http://127.0.0.1:7792/v1`, `Authorization: Bearer` from the `iris=` line of `~/.agent-workflows/data/door-tokens`. Synchronous multipart; `{text}` (`verbose_json` = one segment, so no timestamps); TTS at `POST /audio/speech`, `response_format` mp3. 401 `{error:{message:'unauthorized'}}`. Every response, errors included, has `agw-run-id` (the run that records the call and its cost). `GET :7792/health` is `make verify`'s downstream check | `agent-workflows/packages/audio/README.md` ("The door on the process", "Caller auth") |
| agent-workflows host | `http://127.0.0.1:7791`, `Authorization: Bearer <AGW_API_SECRET>` (`op://mini/agent-workflows/API_SECRET`), `x-agw-purpose: iris`, `x-agw-caller: iris`, `x-agw-project: iris`, no redirects. Synchronous `POST /triage` and `POST /decide`; flat answers carry `model`, `latencyMs`, `usage` (`costUsd` null when any attempt is unpriced). Every response, errors included, has `agw-run-id`. 400, 401 and 502 `INVALID_OUTPUT` are final, 500 and 503 transient. `GET :7791/health` is `make verify`'s downstream check | `agent-workflows/packages/capabilities/README.md` (triage, decide), `packages/host/README.md` (auth, cancel, idempotency) |
| Hermes | Bearer from `op://hermes/gateway/api-server-key`; SSE named events | `argo/apps/api/src/lib/hermes-upstream.ts` |
| herdr | Newline-delimited JSON over `~/.config/herdr/herdr.sock`: `session.snapshot`, `pane.send_text`, `pane.send_keys` | collie `HERDR_API.md` |
| APNs | HTTP/2 `api.push.apple.com` / `api.sandbox.push.apple.com`. ES256 provider JWT, refreshed every 20–60 min (`@parse/node-apn` regenerates it at 55 min, inside the window). Live Activity: `apns-push-type: liveactivity`, topic `<bundle>.push-type.liveactivity`, `aps.{timestamp, event, content-state}`. Priority 5 doesn't consume the budget, 10 does | `docs/research/2026-10-27-apns-from-bun.md` |

### Configuration and secrets

`server/src/env.ts` is the only parser of `process.env`. On the mini,
`scripts/launch.sh` runs `secrets-run run --env-file=.env.local.tpl
--env-file=.env.mini.tpl [--env-file=.env.mini.otel.tpl]`.

| Variable | Contents |
|-|-|
| `IRIS_DEVICE_TOKENS` | Device tokens |
| `IRIS_DATA` | The data directory |
| `AUDIO_DOOR_URL`, `AUDIO_DOOR_TOKEN` | The audio door base (with `/v1`) and the `iris` caller token. Both register `transcribe` and `speech`. The URL is a plain value in `.env.local.tpl`; `launch.sh` reads the token from the local `door-tokens` file (no 1Password ref) |
| `AGW_URL`, `AGW_API_SECRET` | The agent-workflows host base (`http://127.0.0.1:7791`, https or loopback) and its bearer (`op://mini/agent-workflows/API_SECRET`). Both register `summarize` (`triage`) and the decider (`decide`) |
| `HERMES_URL`, `HERMES_TOKEN` | Hermes endpoint and bearer |
| `HERDR_SOCKET` | Path to the herdr socket; registers the `herdr` destination and serves `GET /v1/herd` |
| `BRAIN_DIR` | The brain checkout; registers the `journal` destination (notes in `Inbox/`, then `git push`). Optional: unset leaves journal unregistered, not degraded. `launch.sh` sets it on the mini when `~/SourceRoot/brain` exists |
| `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` | APNs credentials |
| `OTEL_*` | Telemetry export |

New refs go into `dotfiles-private/headless.refs`.

## 4. iOS app

### Targets

| Target | Contents |
|-|-|
| `Iris` | The app: composition root, scenes, App Intents, `AppShortcutsProvider`, notification delegate |
| `IrisWidgets` | `ControlWidget` (start/stop), the Live Activity (`ActivityConfiguration` with Lock Screen + Dynamic Island) |
| `IrisNotifications` | `UNNotificationContentExtension` hosting SwiftUI (result card, [Play]) |

An App Group, `group.com.jkrumm.iris`, shares the device token (Keychain
access group), recent results and settings.

### Composition and connection

`CompositionRoot` is the one place that picks adapters, from the launch arguments, once:

| Mode | Selected by | API | Media | Connection |
|-|-|-|-|-|
| Fake | `-IrisFakeCapture` (all UI tests, `make run-sim`); add `-IrisFakeOffline` and the first `createMemo` and `createTextMemo` fail with no network | `FakeAPIClient` + `SampleData`; the capture stack runs the real outbox and `CaptureSession` on `FakeCapture`, an in-memory queue, a silent microphone and `FakePipeline` (a completed take walks to `notified` with a fake transcript and answer) | silent WAV clips | none; no Keychain |
| Production | no such argument | `ReconfigurableAPIClient` → `URLSessionAPIClient` | `AuthenticatedMediaSource` + `MediaDownloader` | Settings → Connection |

The server URL and device token are typed in Settings → Connection. The token is a generic-password Keychain item (service
`com.jkrumm.iris.device-token`, no explicit access group, so it lands in the first `keychain-access-groups` entry, the App Group's, which the
widgets and the notification extension can read later); the URL, which is not a secret, is in `UserDefaults`. Every model holds the same
`ReconfigurableAPIClient`, which forwards to the `URLSessionAPIClient` for the saved connection and is swapped on Save, so no model is rebuilt.
The form accepts https only; plain http is accepted for `localhost`, `127.0.0.1` and `::1` (simulator dev), so the bearer token never
crosses a network in cleartext. With nothing saved the app opens on the Settings tab, shows "Not configured" with the form, and loads nothing (the client would answer
`APIError.unauthorized`, "token missing"); there is no fallback to the fake. Saving bumps `connectionRevision`, which restarts `start()`: reload
Settings and Stats, load History, reopen the event stream.

### Thread view

A History row opens the conversation when `Memo.opensThread`: a chat (`mode == chat`) or a turn that continues a thread (`threadId != id`); a Hermes memo in its own
session (`threadId == id`) is one answer and keeps the detail, which gets a Conversation button when it has a `threadId`. `ThreadModel` loads
`GET /v1/threads/:id` and derives the turns from the memos and messages: a user turn per memo with a transcript, an assistant turn per reply, and for a memo that
has no reply yet either a **pending** turn (the step dashes from the memo's state, a caption) or, for `failed`, the server's error. A `memo.updated` event for any
memo of the thread bumps History's revision of it, the screen reloads, and the pending turn turns into the answer in the same place with a short fade and height
animation (none under Reduce Motion). **No token stream**: Hermes is final-answer only and `act` stores the final text (mother, 2026-10-28), so the reveal is the
client's, never a fake typing effect. A memo sent from the screen (`didSend`) shows at once, then the fetch replaces it with the server's version.

**Textual** (`gonzalezreal/textual`, MIT, 0.5.0 released 2026-06-15, SwiftPM `https://github.com/gonzalezreal/textual` pinned `exact: "0.5.0"` in `IrisUI`; iOS 18 / macOS 15
minimum, depends on `swiftui-math` and `swift-concurrency-extras`; checked against its README and `Package.swift` at that tag, not from memory). `StructuredText(markdown:)`
renders headings, emphasis, links, lists, block quotes and fenced code with its Prism-based syntax highlighting (the colors are ours, "Reply layout and code themes" below); code blocks scroll sideways
inside their card, text is selectable. Its table label is opaque to a style, so a table cannot become cards through `TableStyle`. `MessageBlock.split` therefore cuts the reply
into blocks first, with the server's fence rules (CommonMark: same character, at least as long, nothing after the closing fence; an unclosed fence runs to the end): markdown goes to
Textual, a GitHub pipe table to `MarkdownTableView` (`ViewThatFits`: a grid while it fits the width, else one card per row titled by its first cell, never a sideways scroll), and
the nth top-level ```` ```mermaid ```` fence to `MermaidImageView` with the same index as `ReplyBlock.index`. A fence the server did not render (no block with that index) stays code.
The diagram is the PNG of the current appearance (`png.light` / `png.dark`, drawn at 2x), fetched through the I1 authenticated media path (`MemoMediaSource.asset`, `MediaDownloader`,
file kept for good since an asset id is never reused) into `ReplyImageStore`, which loads each file once and keeps the decoded image; the card holds the diagram's aspect ratio while it
loads and offers a retry when it failed. A tap opens `ZoomableImageView` full screen: pinch (1x to 6x), drag when zoomed, double-tap between fit and 2.5x, share the image.

Reply by text is the composer sheet bound to `threadId` (mode `chat` for a chat, `hermes` otherwise, no mode chips: the server forces Hermes for a continuation). Reply by voice is
`VoiceReplyCapture`, the thread's capture port: `begin(VoiceReplyRequest(threadId, mode))` on touch-down of the hold-to-talk pill, `end(cancelled:)` on release (slide up 70 pt to cancel;
a hold under 0.8 s is a cancel with a hint). Production and `-IrisFakeCapture` both use `OutboxVoiceReplyCapture`: the take runs through `CaptureSession`, the
outbox creates the memo (bound to `threadId`), uploads and completes it, and `end` answers `sent(memo)` (the thread shows the pending turn at once), `queued` (a toast: it
joins the thread once it is sent) or `discarded`. `UnavailableVoiceReplyCapture` (the pill is disabled) remains for a build whose recorder could not be created.
A typed reply goes through the same outbox (`ComposerModel` → `OutboxService.submitText`). VoiceOver gets a tap to start and a tap to send instead of a hold.

**Reply bar, one row of icons** (Wave 16 I4, the owner's verdict `docs/design/feedback-reply-flow.md`): keyboard (reply by text) · hold to talk (the mic, no text while idle) · locked recording
(`mic.fill` with a `lock.fill` badge, composed because no single SF Symbol says "recording, locked"; every name checked against the 27.1 SDK). The locked recording is a tap-to-start
take through the same `VoiceReplyCapture` port and the same `beginVoice` / `endVoice`: nothing new in the capture path. While it runs the bar shows a cross (discard, `end(cancelled: true)`), the
timer, and the send button (`end(cancelled: false)`); a take under 0.8 s is discarded with a "too short" hint. During a hold the side buttons give way to the timer and the release hint. Accessibility
labels: Reply by text, Reply by voice (hint: hold to talk, release to send), Record continuously (hint: tap to start, tap send when done), Discard recording, Stop and send.

**Reply layout and code themes** (Wave 16 I4). A thread is exchanges: a question turn and its answer, an `ExchangeDivider` hairline before every question after the first. The question is a
card in the accent tint, the answer an open document under the Iris header; inside it headings step down (title 1.35x, 1.2x with a hairline under levels 1 and 2), a quote has an accent rule on a
quiet panel, tables are the grid or cards, a fence is a card with the language on a header line. The code colors are the **JetBrains Light / JetBrains Dark** syntax of the Zed "JetBrains
Themes" extension, which is what the owner's Zed runs (`settings.json`: `theme.light` "One Light", `theme.dark` "JetBrains Dark", no `syntax` or `theme_overrides`; the light side is the same
extension's JetBrains Light, so the pair is one family and the dark half is the Darcula lineage). basalt-ui ships no syntax tokens (its web code blocks use Shiki's `github-light` /
`github-dark`), so these are not generated by `make theme`: they live in `IrisUI/Theme/CodeColors.swift`, the block border and the rest of the chrome stay basalt tokens. Only color values were
taken from the extension. Textual's token names map as:

| Token (Textual / Prism) | Zed syntax entry | Light | Dark |
|-|-|-|-|
| plain, variable, operator, punctuation, namespace | `variable`, `operator`, `punctuation.bracket` | `#080808` | `#BCBEC4` |
| keyword, builtin, literal, boolean, important, atrule | `keyword`, `boolean`, `type.builtin` | `#0033B3` | `#CF8E6D` |
| string, char, regex, attr-value, interpolation | `string`, `string.regex`, `embedded` | `#067D17` | `#6AAB73` |
| number | `number` | `#1750EB` | `#2AACB8` |
| comment, block-comment, prolog, doctype, cdata | `comment` | `#8C8C8C` | `#7A7E85` |
| doc-comment, mark (italic) | `comment.doc` | `#8C8C8C` | `#5F826B` |
| function, function-name, function-definition | `function` | `#00627A` | `#6AA2D7` |
| class-name | `type` | `#A04908` | `#A6BB77` |
| constant (italic), property, symbol | `constant`, `property`, `string.special.symbol` | `#871094` | `#C77DBB` |
| tag, selector | `tag`, `selector` | `#0033B3` | `#D5B778` |
| attribute, attr-name, preprocessor, directive | `attribute`, `punctuation.special` | `#9E880D` | `#B3AE60` |
| url | `link_uri` | `#00627A` | `#57AAF7` |
| entity | `string.escape` | `#0037A6` | `#CF8E6D` |
| inserted, deleted | basalt `status.good`, `status.bad` | basalt | basalt |
| block surface | `editor.background` | `#FFFFFF` | `#1E1F22` |
| language label | `hint` | `#7A7A7A` | `#868A91` |

Textual tokenizes in JavaScriptCore after the first frame, so a snapshot never sees the colors: `ThreadSnapshotTests.codeThemes` pins the table as a legend on the block surface, and the live
highlighting is in the `ReplyFlowReviewUITests` renders (`docs/design/README.md`).

### Authenticated media

`GET /v1/memos/:id/audio` and `/speech` need the bearer header, and AVFoundation has no documented way to send one:
`AVURLAssetHTTPHeaderFieldsKey` is not in the SDK headers (Wave 14 used it anyway). Two documented routes exist:

| Route | For | Against |
|-|-|-|
| `AVAssetResourceLoaderDelegate` on a custom scheme | streams; no wait before the first sample | the delegate has to answer content-information and byte-range data requests itself, re-issue them as `URLSession` range requests, and survive scrubbing and cancellation; it is the most code and the most ways to hang the player |
| Authenticated `URLSession` download to a cache file, then `AVPlayer(url: file)` | ~30 lines; every AVFoundation feature (duration, seeking, end of clip) works on a local file; the bearer header never reaches AVFoundation | the first play waits for the download |

Chosen: the download. A memo is a voice note of seconds to a few minutes (AAC, tens of KB per second at most), the first play waiting for it is
acceptable on the tailnet, and the second play is instant. `MediaDownloader` writes `Caches/iris-media/<memo>.audio.m4a` and
`<memo>.speech.mp3`. The recording is immutable and kept (`MediaRequest.isReusable`); the speech is derived per call from the current reply and
fetched again on every load, replacing the file. The OS may purge `Caches`; a missing file is simply downloaded again. A non-2xx answer throws
and leaves no file. Revisit the resource loader only if recordings grow past a few minutes.

**One downloader, bounded (Wave 16 I2).** The app has one `MediaDownloader` (`.shared`), so every player and the reply images share one `URLSession` instead of one per
`MemoPlayer`. A download is single-flight per URL and cache name: a second ask while the first is on the wire joins it (the download is a task of its own, so a caller that stops
waiting does not cancel the others'), and a failure is not remembered. The session's resource timeout is 300 s (the default is a week), so a hung request cannot hold a flight or an image slot for good. `ReplyImageStore` fetches at most three files at once; the rest wait for a free slot in order. The cache
follows the memos: `evict(memoID:)` removes `<memo>.*` (recording, speech, diagrams) when History deletes a memo, hides a discarded one, or sees one deleted on another device
(`memo.isDeleted` on the refresh, or a 404). Nothing else prunes `Caches`: a memo purged while the app was closed keeps its files until the OS reclaims them.

### Optional summarize, money, offline History (Wave 16 I2)

- **A memo without a summary** (`summary == null`, `notified`, a failed `summarize` step; S1) reads as done. The History row and the detail header fall back to the transcript on
  one line, cut at 60 characters with an ellipsis (the server's own clip for alerts, `Memo.clipped`); the detail has no summary paragraph. In the waterfall the failed step is
  **failed-but-optional** (`StepWaterfallRow.optionalNote`): a warning triangle and amber error box instead of the red cross, "Optional · the memo is done without it", the attempts,
  and **[Retry from Summarize]** (and the retry icon in the action bar), which sends `POST /retry {from: "summarize"}`; the server re-runs summarize and notify, the SSE refresh
  brings the summary back. Only `summarize` is optional; a failed step of a `failed` memo is still the memo's failure. Fixture: `memos.detail.response.summarize-failed.json`
  (decode test in `IrisCore`); the fake API takes that retry on a `notified` memo (back to `acted`), and `SampleData` has one such memo.
- **Money** is `StepText.dollars`: US dollars as the user's locale writes them, two decimals, no fixed `$` ("$0.04", "0,04 $"). The step chip, the waterfall total and the Stats
  tiles and their per-memo caption all use it. A step that costs under half a cent therefore reads "$0.00"; the old four-decimal chip is gone on purpose (the cents are what the owner
  asked for, the exact cost is in the server's step row).
- **History without a connection** shows "Not connected" with an Open Settings button (Settings → Connection) instead of a blank list; it follows the form's saves
  (`CompositionRoot.isConfigured` reads `connectionRevision`).
- **The hidden set survives a relaunch.** A memo this device discarded (a cancelled take, a discarded queue row) is hidden from History until the server `DELETE` settles. The ids live in
  a `HiddenMemoStore` (`UserDefaults`, `iris.history.hiddenMemoIDs`; in memory on fakes, so a UI test starts clean) and are cleared by `CreatedMemoLog.settle`, which the uploader calls when
  the delete is over (200, 404 or 409) and `discardQueued` calls when the user stops trying a stalled one. After a 409 (the memo left `receiving` before the delete landed) the memo is a real
  one and shows again with the next refresh. `CreatedMemoLog` hands hide and unhide to History through one ordered stream, and at launch `reconcileHidden` forgets every hidden id that has no delete queued in the outbox (a discarded take
  whose create never landed has none to settle). Known follow-ups: eviction happens when the delete returns, so an Undo re-downloads the memo's media; a download in flight while its memo is evicted
  can still land its file.
- **Detail toasts** follow the thread view's rule: a toast has an id, its timer is a task owned by the model, and a newer toast (or a dismiss) cancels the older timer, so a stale timer
  never hides a newer toast with the same words.
- **The fake API answers a typed memo**: `FakePipelineUploader.create` starts the fake pipeline for a text item (routed, then `notified` with a canned answer), so the text reply
  flow runs to its answer on fakes (`ReplyFlowReviewUITests` shows it).

### Routing on iOS (Wave 16 I3, R2)

- **One mode picker.** `ModePicker` (chips over `ChoiceChips`) is the composer's picker and the record control's: a tap on the record accessory still records in Auto, a
  long press opens a context menu with the voice modes and "Choose mode…", which opens `RecordModeSheet` (the same chips, one line on what the mode does, Start). A voice take offers Auto, Journal, Hermes, Chat and Transcribe (`MemoMode.voiceModes`; Transcribe has the `text.alignleft` icon and ends the memo with its transcript: History shows the transcript as the headline with "Transcribe" as the route label, the detail has a Transcript section and no Reply, no route card and no "Wrong route?"; its dashes and waterfall hold transcribe and notify only); Tab is
  left out because the tab is named while speaking, the composer keeps it. The accessory stays a `Button` with a context menu: a tap/long-press gesture on a plain label made taps elsewhere on History miss intermittently (the smoke test failed 2 of 6 against 0 of 6 on the baseline).
- **Answering a park.** `RouteAnswerModel` / `RouteAnswerSheet` (the panel itself is IrisUI's `RouteAnswerPanel`, snapshot tested) call `POST /v1/memos/:id/route`. A pinned
  needs-route History row has a trailing swipe action "Route…" (a button inside the row fought the row's `NavigationLink` for the tap and an extra row made the top bars blur the pinned memo), the memo detail a card with the park reason and a "Route to <suggestion>…" button. The sheet shows `routeReason`, preselects
  `routeSuggestion` (`tab` reads as `herdr`; Hermes without one), and for herdr reads `GET /v1/herd` and requires a tab (one tab is preselected; an unreadable or empty herd says so and blocks Send).
  `400 <dest> not available` keeps the sheet open naming the destination, `409` says the memo was already routed and refreshes History, `404`/transport are plain sentences.
- **Presentation hosts.** The route sheet from a History row is presented by `RootView` (next to the mode sheet), not by `HistoryView`. With `.sheet(item:)` over `RouteAnswerSheet` in History's modifier chain, the list's top scroll edge mis-sized on some launches in suite order (a blur over the title, chips and first rows, taps and swipes there dead; `SmokeUITests` failed 2-5 of 15 launches, `origin/master` and the branch without the sheet 0 of 45). A trivial sheet body, one merged `sheet(item:)` enum, an animation-free list and a fixed-height chip bar did not change it; hosting the sheet at the root did (Smoke 15/15, the full suite 28/28). The detail's own sheet is unaffected.
- **Correcting after act.** A memo in `acted`/`summarized`/`notified` with a route shows "Wrong route?" in the detail header; the same sheet, titled "Correct the route", sends the same
  request. The server answers 200 and only logs it, so the sheet says nothing is sent again and the memo stays as it was.
- **Play.** `SpeechPlayer` is the app's one spoken-reply player (one `MemoPlayer`, remembering whose reply it holds): the detail's Play, `PlayReplyIntent` and spoken replies go through it,
  so replies never overlap; the recording of a detail and the speech pause each other (`MemoPlayback`; `SpeechPlayer.pauseRecording` also covers a spoken reply that starts on its own, and a pause cancels a reply still downloading). It plays `GET /v1/memos/:id/speech` (the server's speech variant) downloaded with the
  device token by `MediaDownloader`. `PlayReplyIntent` is an `AudioPlaybackIntent` (runs in the app process; `PlaybackIntents.handler` is the composition root, which fetches the memo and plays);
  it is compiled into the widget too. The done Live Activity card and the expanded island have a Play button (`LiveActivityPanel`'s `doneAction` slot, `Button(intent:)`). Notifications have no action slot
  in the code yet (no category is registered; `MEMO_DONE` actions stay as designed above), so none was added. Compile-checked only: whether a suspended app may start playback from the Live Activity is spike S3, fallback is opening the app.
- **Spoken replies.** Settings → Playback toggle, persisted in `UserDefaults` (`SpokenRepliesStore`, off by default). When on and the scene is active, `memo.done` (`HistoryModel.onMemoDone`) makes
  `SpokenReplies` fetch the memo and speak it if it is `notified`, has a reply, is not deleted or archived, and **this device created it** (`CreatedMemoLog`): the Mac's memos do not talk on the phone.
  Once per memo per launch. A reply that finishes in the background is a notification; Play speaks it on demand.
- **Per-route mic rules (R-CAP-4).** The capture engine already keeps `[routeFingerprint: preferredPortUID]` and applies the rule when a take starts (`CaptureSession`); Wave 16 adds the UI:
  Settings → Microphone shows the active route (`RouteSnapshot.outputNames`, new, for display only; the fingerprint is still the sorted output UIDs) and its inputs, Automatic removes the rule.
  Only the active route is editable: other routes get their rule when they are the active one (the rules store holds fingerprints, not names). Device-verified: nothing (no phone paired); simulator: the fake route manager.
- **Tests.** Unit: `RouteAnswerModelTests`, `SpeechPlayerTests`, `SpokenRepliesTests`, `MicRulesModelTests`, `MemoPlaybackTests`. Snapshots (light + dark): the route panel (parked + suggestion, herdr tabs, herdr unreachable,
  correction with a refusal), the mic rule list, the done card and island with Play. UI (`RoutingUITests`, `-IrisFakeCapture`): answer a pinned memo, herdr needs a tab, answer from the detail, correct a route,
  Play toggles, long-press mode picker incl. Chat, a mic rule picks the input of the next take, the spoken-replies toggle. The fake API's needs-route sample carries a reason and a suggestion, and the fake herd has two tabs.

### UI tests on the hosted runner

"Failed to terminate com.jkrumm.iris" on `StatsSettingsUITests` / `MemoDetailUITests` / `ReplyFlowReviewUITests`: the one log that was kept (run 40829501216) shows it inside
`XCUIApplication.launch()`. That call first ends the instance the previous test left running (`Terminate com.jkrumm.iris:<pid>`), the loaded VM then answers nothing for ~55 s, and
the failure is charged to the next test. The app is idle at that moment (no app-side hang found; the earlier flakes have the same shape but their logs were not kept, so that part is
an inference). Instead of guessing at the app, every UI test class now derives from `IrisUITestCase`: the app is started through
`start(_:)` and ended in `tearDown` (so the next launch has nothing to end), a terminate that stalls is retried, and its failure is recorded as an expected failure
(`XCTExpectFailure`, non-strict, matched on the message); the third launch attempt is strict, so an app that really cannot start still fails the test. Sampling the app at teardown on
the runner needs a workflow step and was left out of this change (owned files: `apple/**`).

### Capture engine (`IrisCapture`)

- **`AudioSessionController`:**
  - `.playAndRecord`, mode `.default`, options `.allowBluetoothHFP`,
    `.allowBluetoothA2DP` and `.bluetoothHighQualityRecording` (falls back to
    HFP; not available in the EU);
  - `setPrefersNoInterruptionsFromSystemAlerts(true)`;
  - interruptions: iOS 27 `didBecomeInactive` / `resumptionRecommendation`, iOS 26
    `AVAudioSession.interruptionNotification` (what the iOS 26.6.1 test phone runs;
    `AVAudioSessionAdapters.swift`). The take pauses (a segment boundary) and
    resumes. **Device (Wave 17 D2, iPhone 15, iOS 26.6.1): a Siri interruption mid-take
    paused and resumed cleanly (the `interruptionNotification` branch works), but
    three other paths lost audio and, in the first, left the UI saying RECORDING:
    a resume with the app in the background and one lock case ("engine resume
    failed"), a stop that hit a 10 s scene-update watchdog, and an uncaught
    `NSException` from `installTap` inside `handleConfigurationChange()` (a route
    change to the AirPods, or a start with them connected), which aborts the app.
    The fixes are Wave 17 I7: build the tap format from the node's current format,
    never let `installTap` throw, put a failed recorder where the user sees it.**
- **`RouteManager`:**
  - lists `availableInputs`, applies `setPreferredInput` after activation, and
    reads back `currentRoute`;
  - per-route rules in device-local settings (`[routeFingerprint: preferredPortUID]`),
    applied at start and on route change;
  - publishes `currentInput` for the UI and the Live Activity.
- **`SegmentRecorder`:**
  - an `AVAudioEngine` input tap → `AVAudioConverter` → `AVAudioFile` (AAC,
    16 kHz mono, about 32 kbps);
  - rotates files every 10 s of frames, on a mic switch, and on an
    interruption;
  - each closed file goes to the `Outbox`; a segment still open when the app dies or the recorder fails stays an unfinalised m4a (no `moov` atom, ffprobe cannot read it), which the startup sweep quarantines (Wave 17 D2: three such files, a few seconds of audio each; a crash-safe container is the fix);
  - a level meter is fed from tap RMS;
  - an engine configuration change restarts the engine and starts a new
    segment.
- **`Outbox`** (Wave 15 I3): a persistent queue of **whole items**, in one JSON file (`Application Support/Iris/outbox.json`,
  written atomically, each segment named by **file name only**: the app's data container gets a new path when a build is installed over it (found on the first device, Wave 17 D1b), so an absolute path saved by an earlier run pointed at nothing, the upload failed as "the recording file is gone" and stalled while the audio sat unharmed in the new container. `JSONFileOutboxStore(segmentDirectory:)` puts every segment in the current capture directory on load, which also heals a record written with absolute paths, and a segment that had stalled on such a stale path with its file present is retried once; a file that is really gone stays stalled. A file that cannot be read or decoded (including a newer build's enum case) is an **error, never an empty queue**: it is left on disk untouched and the outbox reports itself closed (below), until Settings **"Reset outbox"** (Wave 16 I1) renames it aside: `outbox.quarantined-<UTC timestamp>.json`, kept next to it, never deleted, its segment files untouched, and a fresh empty outbox opens. Diagnostics lists the set-aside files with a `ShareLink`. A second tap while the reset runs joins it (`CaptureStack` keeps the one reset task) and gets its outcome; it is not reported as a failure. The reset claims the move in the same actor turn it starts (the stack already knows the file is unreadable from the refresh that offered the button), so no `open()` can read the file between the tap and the rename. An item whose write fails (a full disk) is taken back out and refused, so nothing is ever "queued" that a kill would lose. Three kinds of work, all
  idempotent on the server, so a retry after a lost answer is harmless:
  - A segment `PUT` for a memo that has left `receiving` is 409 `bad_state`, and the server answers it before it compares bytes. `APIOutboxUploader` then asks `GET /memos/:id` what the server holds: with `segmentCount` above this index the segment is **delivered** (the memo was completed with it: a lost answer, or the audio sent by hand), `complete` returns the memo it has and the queue clears; with fewer, the local file is the only copy, so it is **set aside** (the capture directory's `quarantine/`, which Settings counts and sizes) and the entry clears, never deleted. No place to keep it, or no answer to the lookup, is a stall or a retry, not a decision. A 409 `conflict` (other bytes) stays a refusal.
  - **`create`**, one per memo or message (`OutboxItem`: memo id, mode, thread id, text or voice, queued-at). A typed memo or chat
    message is `POST /memos/text` and is done with that call; a take is `POST /memos`. A take is created once it has something to
    send (its first closed segment, or its end), so a take cancelled early never reaches the server and leaves no stuck `receiving`
    memo; the segments of a memo and its `complete` wait for its `create`. A take cancelled *after* its first
    segment closed (so after the memo was created) is deleted on the server: discarding queues an `OutboxDeletion` (persisted, `DELETE /memos/:id`,
    which the server allows on a `receiving` memo) next to the other transfers, retried with the same backoff and kept until the server answers. Only a 200, a 404
    (gone) or a 409 (the memo left `receiving`) ends it; **anything else is never dropped**: a delete that stalls (a refusal a retry cannot change, a 401, out of attempts)
    stays in the queue as a row of its own (`OutboxQueueItem.isDeletion`, kind "Discarded memo" in Settings, the stall reason shown) until "Retry now" succeeds or the user chooses "Stop trying".
    The `DELETE` waits for a `create` still on
    the wire, so it cannot overtake the request that makes the memo. It is queued whenever the create **may have reached the server**:
    `OutboxItem.createMayHaveLanded` is set when the create is handed out and cleared only by a refusal for good (that may belong to another device's memo and is
    not ours to delete), so a create whose answer was lost, was cut off by shutdown, or was on the wire when the app died (a relaunch resets it to pending)
    still gets its `DELETE`; a take that was never created and a typed item get none. A discarded take's queued `DELETE` is not the take: the Live Activity follower and
    the first-attempt watch ignore it, and the banner does not count it as sending. The item and its segments leave the queue at once and the files go with the next save, so a segment or
    `complete` that arrives late (the server answers 409 `bad_state` for the deleted memo) finds nothing queued and is dropped, never a stall. History hides
    the take from the moment of the cancel (`CreatedMemoLog.forget` → `HistoryModel.hide`; a refresh or a late create cannot bring it back; the hide happens only once the outbox is known to open: a discard that cannot reach it queues no `DELETE` and hides nothing);
  - **segments** (`PUT /memos/:id/segments/:n`), one entry per (memo, segment), uploaded while the take runs, at most two in flight;
  - **`complete {segmentCount}`**, only once the take is finished and every index is uploaded. A segment file is deleted only after
    `complete` succeeded (or the user discards the item).
  Retries back off `2 s · 2^(n-1)`, capped at 300 s, plus up to 25 % jitter, and the timer is a persisted `Date`, so it survives a
  relaunch. At once for a refusal a retry cannot change (a 4xx other than 408/429: unknown thread, 409 another body, 400 too long,
  413), or after `maxAttempts` (10) failures that are not **transient**, a transfer **stalls**: nothing is scheduled, the Settings row
  shows the reason, and "retry now" (fresh attempt count) or "discard" is the way out. A transient failure (no network, a 5xx, a
  408 or 429: `TransientTransferError`) backs off for as long as it lasts and does not count toward `maxAttempts`, so a long
  stretch offline never stalls the queue; a 401 (the token may still be fixed), an undecodable answer and a segment file that
  exists but cannot be read (data protection before the first unlock; only a missing file is permanent) are retried and do count.
  A segment is held back from upload until a save that carries it has landed (a crash between the upload and the save would
  orphan a segment the server already has); a failed save is retried on a timer with the same backoff, `Outbox.saveFailure()` says
  why, and Settings shows it. A finished take's record is saved the same way (a relaunch finishes it from the segments on disk). Since every dispatch is saved before it is
  sent, a save that fails sends nothing: the handed-out transfers go back to pending (a create's `createMayHaveLanded` as it was) and the save's retry timer resumes them.
  A first attempt the server refuses for good (a 4xx a retry cannot change) answers `SendOutcome.stalled(reason)`, not `queued`: the
  composer stays open with the text and the reason, and the refused item is removed from the queue so it cannot go out as a second
  copy. A take's stalled item stays queued for Retry and Discard.
  An item is saved before it is handed out (it is withheld from dispatch while the first save is out, so the server never creates a memo
  the queue then refuses), and so is every dispatch: `resume()` saves the state that marks a transfer as handed out (`createMayHaveLanded`
  among it) *before* the request starts, and drops a transfer that was discarded or retried while that save was out (and sends none of them when the save fails), so a kill with a create on the wire
  still leaves the flag a later discard needs, and a segment file is deleted only after a save that no longer lists it has landed (a failed write keeps
  the files; the next successful save removes them). A take that is still being recorded always shows as `recording` in the queue,
  whatever its create is doing, so Settings offers neither Retry nor Discard on it.
  **A crash between the create going out and its answer being saved** is recovered by that same order: the dispatch (`createMayHaveLanded = true`, create `uploading`) is on disk before the request
  starts, so after a kill the record says "a create may exist". The relaunch turns the `uploading` create back into `pending` and sends it again (the server answers a repeat of the same memo id, idempotent),
  and a discard before that send queues the server `DELETE` from the saved flag. Pinned by `OutboxCrashRecoveryTests`.
  `OutboxService.resume()` (launch, a changed connection, the app coming to the foreground) makes every transfer that is waiting
  out a backoff due at once, keeping its attempt count; a stalled one waits for the user. A take the app died in the middle of is finished with the segments it had (contiguous from 0), or dropped when it had none.
  **Startup sweep** (`Outbox.sweepOrphans(using:)` over the `SegmentFileStore` port, production `DirectorySegmentFiles`; run by `CaptureStack` right after the queue loads and before anything is sent or recorded; the sweep reaches the queue only through `segmentFileNames()` / `adoptSwept(_:)`, the machine and its bookkeeping stay private to `Outbox`): a segment file is written before the
  queue file that names it is saved, so a crash or a failed save leaves files no record owns. Each `<memo id>-<index>.m4a` in the capture directory that the queue does not
  know is **adopted** when it belongs to a take the queue holds, fills one of its indices (below its count, or the next one after a take recovered from a crash, which then grows) and
  opens as audio with frames in it (a truncated AAC file does not); otherwise it is **moved** into `capture/quarantine/`. A file that a set-aside queue file names stays where it is, and when a set-aside queue file cannot be read, every candidate stays where it is (the read failure is logged).
  **Nothing is deleted** (the files of a memo the server completed, left by a crash between the save and the removal, are quarantined too).
  **Set-aside files are surfaced, not bounded by deletion.** `capture/quarantine/` and the `outbox.quarantined-*.json` files grow only when something went wrong, and the app never removes them on its own: Settings
  shows "Kept on this device" (count and size, `SetAsideSummary`) with a share/copy of the list (names, sizes, dates; no audio), and past 50 files or 200 MB a note says so. A delete action waits for the owner's word.
  Everything runs on a default `URLSession` (`URLSessionAPIClient`); the background `URLSession` and the `result?wait=600`
  long-poll as a background download are not built (device-only, below). The app side is `OutboxService` (submit text, await the
  first attempt for six seconds and answer `sent(memo)` or `queued`, retry, discard, the queue for Settings) over a lazy
  `CaptureStack` (the outbox and the `CaptureSession`), with `APIOutboxUploader` as the network adapter and
  `CreatedMemoLog` as the hand-off of the memo the server returned.
- **`CaptureSession`:** one take behind one handle. `start(TakeRequest)` mints the memo id, configures and activates the session,
  applies the route rule, starts the recorder and registers the take with the outbox; closed segments go to the outbox while the
  take runs; `stop()` flushes the last segment and finishes the memo (a take that never closed a segment is dropped); `cancel()`
  discards the memo and deletes its files; an interruption pauses the recorder at a segment boundary and resumes it when the system
  recommends; `switchInput` rolls the segment, and so does a route rule that applies mid-take (behind the same gate, only while
  recording or paused), so one file never holds two inputs. `updates()` is the state stream the UI and the Live Activity follow.
  A recorder failure (`.failed`: a segment write error, an engine that will not resume or restart) is a take failure: the session
  stops the recorder, moves the take to phase `failed` (`TakeState.failure` says why) and holds it for the user's `stop()` or
  `cancel()`. `stop()` then finishes the memo with the segments that really closed (`TakeResult.failure` set) or, with none, throws
  `CaptureError.recordingFailed` instead of returning `nil` (which means nothing was said); the thread screen tells the user.
  Both actors are reentrant, so every write that follows an `await` re-checks what it assumed or is authoritative: `pause` and
  `resume` (and the interruption handlers) leave a take that failed meanwhile as `failed`, a failure that comes in while the
  recorder is starting is parked and applied once the take is up, and the persist call reports whether a save that was started
  after the caller's change landed, not whether the last save did.
  `start`, `stop`, `cancel`, `pause`, `resume`, `switchInput` and the interruption handlers run one at a time through an internal FIFO gate (a late resume cannot write `recording` over a take that has stopped), and `start` claims the take (phase `starting`) with no
  suspension after the gate: a second start finds the first take and is rejected, a `cancel` that lands while the take is starting or
  stopping waits for that to finish and then ends it (so no microphone is left running with no state), and a stop's wait for the
  recorder's last event is never shared with another caller. Both waits are **bounded** (10 s on the injected clock, `stopTimeout`): `recorder.stop()` itself (a recorder whose stop never returns is given up on,
  logged, and treated as stopped; the same on the event pump after a failure) and the recorder's `.stopped` event. A recorder that never says it stopped must not hold the gate or block the next take, so `stop()` gives up
  and returns the segments that closed (`TakeResult.failure` = "the recorder did not stop") or, with none, throws `CaptureError.recordingFailed`. **The memo is not finished at the timeout**: the tail segment the
  recorder was flushing can still close and is queued like any other, and the `.stopped` event finishes the memo with the whole take; if it never comes the memo is finished after a grace period of the same length with
  the segments that closed, and only a segment that closes after *that* is ignored (its file stays for the next launch's sweep). The timeout marks the take as waiting in the same actor turn that resumes `stop()`,
  so a `.stopped` that lands between the two finishes the memo once and is not mistaken for a late one. `cancel()` has the same bounds, and drops the tail. A `stopped` that did arrive while `stop()` hung counts as reported (the memo is finished once, no failure). While a given-up `recorder.stop()` has not returned the recorder may still hold the microphone, so `start` refuses (`engineFailure("the recorder is still stopping")`) until it does. `TakeController.start` is single-flight: a second start while one is in flight (the Control and the record button together, a double tap)
  joins it and returns the same memo, as does a start that finds a take already running; `TakeController.cancel()` throws when the capture session cannot be opened and `TakeModel` shows the failure instead of looking done.
- **`CaptureStack` never queues into memory.** If the persistent queue cannot be loaded (the file unreadable before the first unlock after
  a reboot), the stack stays unbuilt: the composer keeps the text and shows why, a voice take and the start intent refuse to start,
  Settings shows "the outbox cannot be opened", and nothing is written anywhere. The next call (`resume()` at launch, a pull to refresh, the
  next send) tries the real store again. Callers that wait on the same failed build all get the error, and only the build they
  waited for is cleared, so two builds never run over one `outbox.json`. A file this build cannot **decode** is told apart from one that cannot be read right now (`OutboxAvailability.unreadable`
  vs `.unavailable`): only the first offers the reset, and only the first is touched by it. A reset whose fresh outbox then fails to open says so (the old file is set aside and kept, no new outbox yet) instead of reporting that nothing changed.
- **Memo ids** are minted at start: a UUID v4, which also serves as the trace
  id.

### Start paths

- **The intent:** `StartMemoIntent: AudioRecordingIntent` starts the engine and
  `Activity<MemoAttributes>.request(...)` in `perform()`. Apple requires the Live Activity, or the recording stops.
  Built (Wave 15 I3): the intent file lives in `Iris/Intents/` and is compiled into the app and the widget extension (the
  `ControlWidget` names the type, the app performs it); `perform()` calls the `CaptureIntentHandler` the composition root
  registered at launch (`startMemo()`: server saved, microphone permission, `CaptureSession.start` in `auto` mode, then the
  Live Activity through `TakeLiveActivityCoordinator`). It compiles and runs in the unit tests on the simulator
  (`StartMemoIntentTests`: the fake stack, a recording `TakeLiveActivity`); **pressing the Control and a real
  `Activity.request` from the background are device-only.** Device result (Wave 17 D2, iPhone 15, iOS 26.6.1, `docs/spikes/S1-lock-screen-start.md`): the Record control, from the Lock
  Screen and from Control Center, starts nothing (no take, the app is not launched, only the widget extension runs); Siri has no phrase (no `AppShortcutsProvider`); a take started in the app
  requests its Live Activity and runs fine. So S1 has not yet shown that an `AudioRecordingIntent` start works from a control: the likely cause is the intent running in the extension
  process without the app's handler, and Wave 17 I8 decides between a fix and the `openAppWhenRun` fallback below.
- **Callers:** the `ControlWidget` button calls the intent. So do Siri ("Record
  with Iris") and Control Center.
- **Fallback, accepted by the PRD:** if the system refuses to start a Live
  Activity from the background ("Target is not foreground", reported once), the
  control uses `openAppWhenRun` and the app auto-starts. Spike S1 decides.
- **`StopMemoIntent`, `SwitchInputIntent`, `PauseMemoIntent` (built, Wave 15 I4), `PlayReplyIntent` (not built):**
  `LiveActivityIntent`s used by the Live Activity buttons. The first three call the app's `TakeController` through `CaptureIntentHandler`; pressing them from the island is device-only. `PlayReplyIntent`
  activates the session and plays `/speech`. Verify that playback starts from
  the background (S3); otherwise it opens the app.

### Live Activity (`MemoAttributes`)

- **Static:** `memoId`, `mode`, `startedAt`.
- **`ContentState`** (well under the 4 KB limit):
  - `phase` (recording/paused/uploading/processing/needsRoute/done/failed). `recording`, `paused` and `uploading` are the
    client's own (Wave 15 I3): `TakeLiveActivityCoordinator` sets them locally while the take is on the phone (recording while it
    runs, paused during an interruption, uploading from the stop until the outbox has sent the memo), then `processing`, and the
    server's pushes (`processing`, `needsRoute`, `done`, `failed`; the wire enum and fixtures are unchanged) carry it from there.
    The activity's push token is kept by `ActivityTokenRegistrar` per memo until the activity ends, not until the hand-over: a PUT
    that failed is retried with a growing delay, and a token that rotates later is sent too. One `PUT` per memo is out at a time, so a rotation that arrives while one is in flight is sent after its answer and an older token's slow answer
    can never replace a newer one; the in-flight gate is keyed by memo id, not held on the entry, so a `finish` + `begin` of the same memo during a `PUT` makes the new entry's sender wait and then carry on with the newest token (never two `PUT`s at once).
    The coordinator follows each memo on its own and the activity handle is kept per memo, so a take that starts while the last one is
    still uploading neither cancels nor overwrites it, and a stopped follower writes nothing more.
    A retryable failure (no network, a 5xx) keeps the activity on `uploading`; a stall or a recorder failure ends it as `failed`
    (shown 15 minutes) and a discard ends it at once (`Activity.end`); a sent memo is handed over to the server, not ended. The activity's push token is registered
    (`PUT /memos/:id/activity-token`) once the server has the memo, since it answers 404 before that, and retried on the next update; at
    launch every activity still in a client phase is ended, because nothing moves it on after its process is gone (`endOrphans()` also runs when the connection changes, and spares the takes this process is driving, so changing the server URL mid-take does not end that take's activity).
    The widget renders all seven (timer for recording and processing); on the device (Wave 17 D2) recording, paused and processing were seen, on the Lock Screen and in the island (compact and expanded), the other four not yet. **Without APNs (a Personal Team) nothing moves a processing activity on: every finished take left a "Processing" card counting up, and the system showed one of those in the island instead of the running take, so its Stop / Pause / mic swap were unreachable (Wave 17 I8).** A new take's `headline` carries one line about earlier memos still sending ("1 earlier memo is still sending", client phases only), which the card shows as a note;
  - `inputName`;
  - `routeChip`;
  - `headline` (≤ 60 chars; the Lock Screen truncates around 160 pt);
  - `hasReply`.
- **Timer:** `Text(timerInterval:)` with `numericText` transitions.
- **Lifetime:** 8 h, plus 4 h on the Lock Screen, which is plenty for a 2 h
  take.
- **Updates:** local while the app runs; remote via APNs after suspension (the
  push token is registered per memo).

### Live Activity and Dynamic Island views (Wave 15 I4)

The views live in `IrisUI` (`LiveActivityPanel`, `ActivityPhaseTitle`, `ActivityHeaderTrailing`, `IslandGlyph`, `IslandCompactTrailing`, `ActivityStageDashes`, `ActivityControlLabel`) and take a plain `ActivityPresentation`, so they are snapshot-tested on the
pinned simulator in light and dark (`LiveActivitySnapshotTests`, the island through `IslandMock`: a black pill or card standing in for the system's island); the widget only maps `ContentState` onto them and wraps the controls in `Button(intent:)`.
- **Recording / paused:** the running time (`Text(timerInterval:)`), the microphone, and icon controls: Stop, mic swap, pause or resume (`StopMemoIntent`, `SwitchInputIntent`, `PauseMemoIntent`, `LiveActivityIntent`s compiled into the app and the widget, performed in the app against the same `TakeController` the screens use).
- **Uploading / processing:** a line and the four-stage dashes (record, upload, process, done; the phase decides the stage). There is no per-step progress, because `ContentState` carries no step (the server would have to push one); the dashes fill when the activity updates, which the system animates.
- **Several memos:** each memo has its own activity, so the Lock Screen stacks them and the system picks the most recent for the island and shows the other as a small circle. A take that starts while another is sending also says so inside its own card.
- **Done card (round 2):** the checkmark and the headline share a first-baseline row, so the mark stays on the first line however far the headline wraps; the phase title has no second check.
- **Device exit checks** (Wave 17 D2, results in `docs/spikes/device-checklist.md`): the Lock Screen card and the compact and expanded island **pass**; the compact banner and the keyboard-up composer **pass**; island Pause works and island Resume **fails** (I7); minimal island, two activities in the island (the stale ones, I8), Stop and mic swap from the island, a Bluetooth route and the car are **not run**.

### Notifications

- **Registration:** `registerForRemoteNotifications()` on every launch, with
  the token sent via `devices/register`. The push-to-start token comes from
  `Activity<MemoAttributes>.pushToStartTokenUpdates`.
- **Categories:**
  - `MEMO_DONE`: [Play] [Reply by voice] [Open];
  - `MEMO_NEEDS_ROUTE`: up to 3 route actions from the payload;
  - [Reply by voice] opens the app in recording mode bound to `threadId`
    (foreground required for capture).
- **Content extension:** headline, route chip, the condensed answer (Textual
  markdown), and an inline [Play] using the shared player.

### Screens

| Screen | Content |
|-|-|
| History | Tabs History · Stats · Settings (no Threads tab). Memo rows (route chip · state · headline · relative time, step-progress dashes while in flight), pinned needs-route rows (a "Route…" swipe action opens the route sheet), day sections, search, quick-filter chips (Favorites, Chats, Needs route, Archived), bottom-sheet filter, native swipe actions (done/favorite, archive/delete with a 5 s undo), pull to refresh, SSE live updates, [+] opens the composer |
| Memo detail | A park card (reason, "Route to …") on a needs-route memo, "Wrong route?" on a finished one (route sheet), transcript, player (play/pause, scrubber, 10 s back, no speed), full-width step waterfall with one `duration · cost` chip per step (money in the user's locale, two decimals), faster/slower vs the stats baseline only above a sample threshold, attempts, a failed optional summarize as a warning row, [Retry from step], icon-only actions (play reply, reply → composer, retry), the reply as markdown; SSE refresh |
| Composer | Typed memo: mode picker (Auto, Journal, Hermes, Tab, Chat), text, send via `POST /v1/memos/text`; from a detail's reply it continues the memo's thread |
| Stats | Volume per route per day / week (Swift Charts), tiles, per-route trends, from `GET /v1/stats` |
| Thread | One conversation as a rendered document (`GET /v1/threads/:id`), opened by a History row of a chat or a continued thread (Wave 15 I2, "Thread view" below): question and answer turns, a pending answer with the step dashes, hold-to-talk and a keyboard button at the bottom |
| Record | Wave 15 I4. **Start from any screen:** the record control is the tab bar's bottom accessory (tap: Auto; long press: a menu with Auto, Journal, Hermes, Chat and "Choose mode…", the mode sheet); memo detail and thread hide the tab bar, so they have none (their banner still shows). A take opens the full `TakeScreen` (mode, timer, level waveform, mic list, pause, Stop, discard with a confirmation); minimizing (chevron) leaves a compact **`TakeBanner`** (dot, running time, mode · mic, "N sending", Stop) pinned under the navigation bar of every screen (`.takeBanner()`), and tapping it returns to the full take. `TakeModel` follows `CaptureSession.updates()` and the outbox; a pause moves the timer's start forward so it counts recorded time. Leaving the app needs no hand-over: the take's Live Activity is requested at the start, so the Lock Screen card and the Dynamic Island carry it from there |
| Settings | Diagnostics (copy a memo id, animated "Copied"), Connection (server URL + device token in the Keychain, status; "Not configured" until saved), Playback (spoken replies toggle), Microphone (the active route's rule), outbox section (the queue of whole items from `OutboxService`: kind, age, state, a retry time or the reason it stalled, retry now and discard; live through the outbox's change stream). Later: default mode |

## 5. macOS app (`IrisMac`)

- **Window and hotkey:** `MenuBarExtra` with `.menuBarExtraStyle(.window)`,
  `LSUIElement`. The global hotkey goes through `KeyboardShortcuts`
  (Carbon-based, no Accessibility prompt) if it holds up on macOS 26, otherwise
  a `CGEventTap`. `NSEvent` global monitors reportedly crash on macOS 26.
- **Panel:** a floating non-activating `NSPanel` for the take, showing the
  timer, level and mic picker.
- **Capture:** the same `IrisCapture` package; Mac input devices come from
  Core Audio, and per-device mic rules are local.
- **Notifications:** live SSE `/v1/events` for status, local notifications
  while it runs, and APNs registration for when it is asleep.
- **Signing:** a stable Apple Development identity. Ad-hoc signing resets TCC
  on every build.

## 6. Shared Swift packages

| Package | Depends on | Tested with |
|-|-|-|
| `IrisCore` | Foundation | Swift Testing: fixture decoding from `contracts/fixtures`, API client against a `URLProtocol` stub, SSE parser |
| `IrisCapture` | IrisCore, AVFAudio | Swift Testing: segment rotation and outbox state machine against a fake engine/clock; real audio only in device spikes |
| `IrisUI` | Textual (0.5.0) | swift-snapshot-testing (1.19.x, Swift Testing traits) for components and Live Activity views, pinned to one simulator runtime |
| `IrisTelemetry` | IrisCore | Swift Testing: batching, relay payload shape, drop-on-overflow |

Swift settings: Swift 6 language mode and complete strict concurrency; app
targets use MainActor default isolation (SE-0466). Verified against Xcode 27.1
(Wave 7, `apple/project.yml`, all schemes build warning-free):

| Setting | Value |
|-|-|
| `SWIFT_VERSION` | `6.0` (the Swift 6 language mode; the compiler is 6.4) |
| `SWIFT_STRICT_CONCURRENCY` | `complete` |
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | `MainActor` (values: `nonisolated`, `MainActor`) |
| `SWIFT_APPROACHABLE_CONCURRENCY` | `YES` |

The UI test bundle sets `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`. Local
packages are `nonisolated` by default (`swiftLanguageModes: [.v6]`, tools 6.2).
Packages never depend on each other except through `IrisCore`; `IrisCapture`,
`IrisUI` and `IrisTelemetry` currently define what they need locally and gain
the `IrisCore` dependency when R1 wires them together.

## 7. UI system

- **Theme:** basalt-ui's color palette, type scale, radius and spacing tokens
  ported into `IrisUI/Theme`. One source file, with a script that regenerates
  it from basalt-ui's token export so the two can't drift.
- **Liquid Glass:**
  - `glassEffect(_:in:)` inside `GlassEffectContainer` for floating controls
    (record button, mic picker, route chips);
  - `.buttonStyle(.glass)`;
  - one transition style app-wide (`matchedGeometry`);
  - Apple warns against many concurrent glass effects, so glass is limited to
    controls and content stays flat.
- **Motion carries state:** a recording pulse, step progress in the timeline,
  `numericText` timers. Nothing decorative.
- **Libraries:** Textual (MIT, the markdown successor to swift-markdown-ui),
  DSWaveformImage (MIT, the live level waveform), SwiftUI-Introspect (MIT) only
  where unavoidable. No glass kits.
- **Process:** an HTML mockup round (history, detail, Record, Live Activity,
  notification card) is reviewed before any screen is built in Swift.
  Snapshots then lock the result.

## 8. Telemetry

- **One trace per memo,** with trace id = the memo UUID without dashes:
  - **iOS:** `capture` root (control press → engine running), then `segment.upload`
    × n, `mic.switch`, `interruption`, `outbox.retry`;
  - **server:** `memo` with a child per step and per downstream call;
  - **iOS again:** `notify.received`, `play`.
- **Server:** `withRootSpan`/`withSpan`/`log` from the copied research-gateway
  files.
  - Resource attributes: `service.name=iris-server`, `host.name=mini`, and
    `deployment.environment`.
  - Metrics as named log events: `memo.completed{route, audio_s, total_ms,
    cost_usd}`, `route.decided{source, confidence, corrected}`, `stt.latency`.
- **Clients:** `IrisTelemetry` buffers spans and logs (in memory plus a file
  for crash survival) and flushes batches to `POST /v1/telemetry` every 10 s,
  on background, and on launch.
  - The server re-emits them as OTLP with `service.name=iris-ios|iris-macos`,
    `device.name` and `service.version` (the app version) as resource attributes.
    The memo trace id is kept as sent, so a phone span and the server's `memo`
    span share a trace.
  - **Wire shape (final):** the TypeBox `TelemetryBatch` in `http/schemas.ts` is
    the contract, the Swift `TelemetryBatch` encodes it. Dates are ISO 8601 UTC
    (milliseconds from the clients), ids lowercase hex (32 trace, 16 span),
    attribute values plain scalars. `dropped` is the client's overflow count
    since its previous batch; the server logs it (`telemetry.relayed`) and does
    not turn it into a metric.
  - **Bounds:** body over 256 KiB is 413 `too_large` (cut off while streaming,
    after the bearer check); more than 500 spans and logs together is 400.
  - **Delivery:** the answer does not wait for the collector. A failed export
    (or one refused because 4 exports are already in flight, so a slow collector
    cannot pile up posts) is counted in a `telemetry.relay_failed` log line
    (signal, record count, error) and the batch is dropped; the client does not retry on it. Delivery
    from the client is at-least-once and the server does not de-duplicate, so a
    resent batch shows twice (`(traceId, spanId)` identifies a span). The export
    is part of the OTel flush at shutdown. Without `OTEL_EXPORTER_OTLP_ENDPOINT`
    the batch is accepted and discarded (`degraded` already lists `otel`).
  - On iOS, MetricKit crash and hang diagnostics are relayed on the next launch.
- **Propagation:** the audio door and the agw host don't accept `traceparent` (factory
  ADR-006 plans it), so Iris spans carry the memo id as an attribute on every
  downstream call. Once ADR-006 lands, `traceparent` is added.
- **Cost:**
  - STT/TTS spend is recorded by the audio door as a run per request (caller `iris`, from the bearer token's
    name); the `agw-run-id` of each call is on the Iris span and log line (`agw.run_id`), so a memo's trace
    leads to its run record;
  - `decide`/`triage` spend is recorded by the host as a run per call (purpose `iris`, the `x-agw-purpose` header; caller `iris` and project `iris`, the
    `x-agw-caller` / `x-agw-project` headers, so the ledger books it to iris, not to `agw`);
    the `agw-run-id` of each call is on the Iris span and log line (`agw.run_id`) as for the audio door;
  - Iris posts no usage rows (they would double-count). It stores per-step
    `usage`/`cost_usd` for the memo detail.
- **Later (not R0–R3):** HyperDX alerts (`iris memo-failed ≥ 1/15m`,
  `iris-ios crash`) to Slack + warden, and a `probe_iris` in
  `devhost-health-check.sh`.

## 9. Testing and verification

| Layer | Tool | Runs where | Gate |
|-|-|-|-|
| Server unit/integration | `bun test`, in-memory SQLite, fake ports, `app.handle(new Request())` | mini, CI | `make check-server` |
| Contracts | Server: response ⊨ `contracts/schema`; Swift: decode every fixture | mini, CI | `make check-contracts`, `swift test` |
| Pipeline end to end (fakes) | `scripts/send-memo.ts` against a server booted with fake downstreams | mini, CI | `make e2e` |
| Pipeline smoke (real) | `send-memo.ts --real` against `iris.mini.<domain>` with `fixtures/audio/de-90s.m4a` | mini | `make smoke` (post-deploy) |
| Swift packages | Swift Testing via `swift test` per package | mini, CI | `make check-apple` |
| Views | swift-snapshot-testing on a pinned simulator (iPhone 17, iOS 27.0; `SIM_NAME`/`SIM_OS` in the Makefile) | mini, CI (`xcode-27`) | `make snapshots` (record with `RECORD=1`) |
| App flows | XCUITest smoke: launch → history → detail; Record screen with a fake recorder (`-IrisFakeCapture`); a launch without it lands on the connection form | mini, CI | `make uitest` |
| Agent verification | `xcodebuild` build/test, `xcrun simctl` (boot + `bootstatus -b`, install, launch, `io screenshot`, `openurl`, `push` for simulated notifications), and the `mobilebuildmcp` CLI (`ui-automation snapshot-ui` / `tap` / `type-text` / `screenshot`) | mini | `@verifier` / the `ios-verify` skill |
| Physical device | `devicectl device install app`; screenshots via `pymobiledevice3 developer core-device screen-capture screenshot` (devicectl has no screenshot verb) | mini → iPhone on LAN | `device` skill |
| Hardware-only (not built or verified by Wave 15 I3) | A checklist in `docs/spikes/device-checklist.md`; also the background `URLSession` for the post-stop upload, background audio keeping the app alive, Bluetooth/car routes, the real `AVAudioEngine` recorder, the Control press and a Live Activity started from the background: Lock Screen control, a 30-min background take, a mic switch iPhone↔AirPods↔car, a phone-call interruption, APNs Live Activity update | my hands | before each R-release |

- **Fakes, not mocks:** every port has a fake used by both unit tests and the
  e2e boot mode (`IRIS_FAKES=1`).
- **Fake capture:** a `FakeCapture` build flag swaps `SegmentRecorder` for a
  file-backed generator, so UI tests and screenshots run without a microphone.
- **Snapshot hygiene:** a reference must come from the same simulator
  runtime. CI and the mini pin the same device and OS (Xcode 27.1 image).

## 10. Agent tooling in the repo

- **No MCP servers** (D17). The `ios-verify` and `device` skills call the CLIs
  directly. UI automation goes through
  `scripts/mbm` → `npx -y mobilebuildmcp@<pinned> <workflow> <tool>`, with
  `--style minimal` and its Sentry telemetry disabled through the environment
  (`MOBILEBUILDMCP_SENTRY_DISABLED=true`, verified on 2.7.1).
- **Swift layer, repo-local** (Iris is the only Swift project; other apps will
  use Tauri / React Native):
  - `.claude/rules/swift.md`;
  - vendored MIT skills `swiftui-pro`, `swift-concurrency-pro`,
    `swift-testing-pro` and `swiftdata-pro` (from `twostraws/*`, pinned in
    `.claude/skills/VENDORED.md`);
  - `.claude/skills/apple-dev` (toolchain + recipes).

  Only the machine toolchain (XcodeGen, `xcodes`, `pymobiledevice3`) lands in
  dotfiles.
- **Iris rules:** `.claude/rules/apple.md` and `server.md` hold the Iris
  invariants, each pointing at its TDD section.
- **Own skills:**

  | Skill | Covers |
  |-|-|
  | `iris-server` | Ports and adapters rules, adding a step/adapter, contracts workflow, running e2e |
  | `ios-verify` | Generate the project, boot the pinned simulator, build-run, screenshot, snapshot record/compare, UI test; where artifacts land (`.artifacts/`, gitignored) |
  | `device` | Install to the paired iPhone, device screenshot, log stream, the hardware checklist |
  | `memo-debug` | Take a memo id → `GET /v1/memos/:id`, then the HyperDX trace via `/otel`, then retry |
  | `apple-capture-notes` | The verified iOS facts (`AudioRecordingIntent` + Live Activity rule, session options, iOS 26 interruption API, EU Bluetooth caveat, APNs headers), so workers don't re-research |

## 11. Build, CI, distribution

- **Local (mini):** Xcode 27.1 (via `xcodes`, at `~/.local/bin`). `make
  generate` runs `xcodegen` with `apple/project.yml`. `make check` covers
  server + contracts + Apple: format/lint, `swift test`, an `xcodebuild build`
  of all schemes for the simulator, and snapshots.
- **Swift lint/format:** `swift format lint --strict` with a checked-in
  `.swift-format` (toolchain-bundled; verify in the setup wave), plus SwiftLint
  only if it is needed later.
- **CI (`.github/workflows/`):**
  - `check.yml` on `ubuntu-latest`: `make check` (server, contracts, guard), then e2e
    with fakes;
  - `apple.yml` on `xcode-27`: generate, `swift test`, build, snapshots, UI
    smoke. It is a preview image, so on queueing trouble switch to `macos-26`
    with Xcode 26.6 and no iOS 27-only APIs.
- **Server deploy:**
  - the research-gateway pattern: deploy clone `~/.iris/app`, data in
    `~/.iris/data`;
  - `com.jkrumm.iris` (KeepAlive) and `com.jkrumm.iris-deploy` (a 120 s poller,
    CI-green and idle gated);
  - logs in `~/Library/Logs/iris*.log`;
  - registered in `dotfiles/docs/architecture.md`.
- **App distribution:**
  - TestFlight internal: `xcodebuild archive` → `-exportArchive` →
    upload with an App Store Connect API key from 1Password (the upload command
    is verified when enrollment completes);
  - builds come from the mini via `make testflight`, and devices auto-update.
  - Until enrollment: a free team, then `devicectl` install over Wi-Fi after
    one cabled pairing plus Developer Mode.
- **Bundle ids:** `com.jkrumm.iris`, `.widgets`, `.notifications`,
  `com.jkrumm.iris.mac`.

## 12. Security

- **Repo:** public, so a pre-commit hook and CI grep reject IPs, `*.ts.net`,
  real domains and token shapes.
- **Device tokens:** 32-byte random, stored as SHA-256 on the server and in the
  Keychain (App Group access group) on the device. Rotation via 1Password +
  `IRIS_DEVICE_TOKENS`.
- **Other credentials** (APNs key, Hermes bearer) live only in `secrets-run` on
  the mini.
- **Exposure:** the server binds loopback and Caddy is the only door, on the
  tailnet. There is no public exposure.
- **Content:** transcripts and audio never leave the mini except to
  the audio door (STT/TTS) and the agw models. APNs payloads carry headlines
  only, never full transcripts; when `summarize` failed, the headline is the
  first 60 characters of the transcript (owner-confirmed, Wave 16); the same rule gives a `transcribe`-mode memo its headline, which is
  always the transcript's start.

## 13. Risks and unverified

| Risk | Plan |
|-|-|
| A Live Activity start from a control intent may need the foreground (one forum report) | S1 (Wave 17 D2, iOS 26.6.1): the control starts nothing at all, with no visible error; not yet the "needs the foreground" refusal, more likely the missing handler in the extension process. I8 fixes it or takes the fallback `openAppWhenRun` + auto-start, accepted by the PRD |
| Built-in mic while connected to the car's Bluetooth is undocumented | S2 on hardware; Wave 17 D2: the AirPods switch crashes the app before the car question can be asked, the car was not run, still open |
| An audio engine cannot restart in the background | Device (Wave 17 D2): resume from the island and one lock case failed with "engine resume failed" and the UI kept counting; a route change to the AirPods (or a start with them connected) aborts the app with an uncaught `NSException` in `installTap`; the take loses its open segment (I7) |
| A segment open at a crash is unreadable | Device (Wave 17 D2): three quarantined segments have no `moov` atom; the "at most 10 s lost" holds but the seconds are gone; a crash-safe segment container |
| Live Activities are server-owned after the hand-over | Without APNs (Personal Team) they stay on "Processing" and hijack the island; I8, and the paid team's pushes must be re-checked in D3 |
| TTS playback from a Live Activity intent while the app is suspended | S3; fall back to opening the app |
| Bun `node:http2` over-dispatch to APNs | Cap in-flight streams (D6); Bun 1.3.14's HTTP/2 `fetch` as a fallback |
| `xcode-27` is a preview CI image | Fall back to `macos-26` (D14) |
| Exact Swift build-setting spellings (default isolation) | Verified in the setup wave against Xcode 27.1 |
| Personal Team cannot sign Push or App Groups; 7-day profiles, 10 App IDs per 7 days | Device builds sign with entitlements minus `aps-environment` and the App Group (`DEVICE_SIGNING=personal`); `DEVICE_SIGNING=paid` signs the tracked files. Verified Wave 17 D1 on an iPhone 15, iOS 26.6.1: build, install and launch work, headless codesign needed no keychain prompt; S3 and the APNs rows wait for the paid team |
| `decide` confidence calibration | Logged decisions and corrections; threshold tuned after 100 memos |
| Voxtral has no timestamps | Plain transcript in R1–R3; revisit if a synced transcript matters |
