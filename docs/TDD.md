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
  audio door, Voxtral), hands the transcript to Hermes, which decides what the memo is and acts with its skills
  (`act`; it reports a `kind`, a headline, a spoken line and the tools it used), and notifies (APNs: Live
  Activity update plus a rich alert). A plain transcription skips Hermes.
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
| D1 | A server on the mini, not Hermes direct | The phone cannot reach Hermes `:8642` (VPS-only grant, privileged bearer) and the audio door is loopback. Credentials stay on the mini | Apps talking to Hermes directly |
| D2 | Iris owns the memo record; Hermes owns conversations | History must survive a Hermes reset and cover non-Hermes memos. Mirrors Argo | Hermes sessions as the only store |
| D3 | Routing is Hermes' job (changed 2026-11-04) | Hermes' skills already route todos, notes, work and answers, and Iris's own router parked 16 of 27 `auto` memos. Iris sends every memo but a plain transcription to Hermes and shows its structured report (`kind`, headline, spoken, tools) | A prefix → `decide` → ask router in Iris (retired, §Pipeline steps) |
| D4 | 10 s segments, uploaded during the take | A crash loses ≤ 10 s, the upload is done at [Stop], and a mic switch is a segment rollover | One file at [Stop] (loses everything on a crash, slow); shorter (request churn) |
| D5 | `AVAudioEngine` tap → `AVAssetWriter` (AAC, fragmented m4a) per segment; the server decodes and re-encodes on concat | Continuous buffers plus edit lists make the concatenated decode gapless. `AVAudioRecorder` stop/start drops audio | `ffmpeg -c copy` concat (priming gaps); PCM segments (too large on cellular) |
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
                                                                                                    ├─> Hermes :8642 (mini tailnet IP)  sessions
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
| `pipeline/` | One file per step; each step is a pure function of (memo, ports) | `createStepHandlers({store, audio, transcriber?, destination?, replyAssets?, notifier})`: `transcribe`, `act`, `notify` |
| `devices/` | Device tokens, APNs and push-to-start tokens, Live Activity tokens | `authenticate`, `register`, `tokensFor` |
| `notify/` | Payload building (alert, Live Activity), APNs transport | `Notifier` port |
| `telemetry/` | `otel.ts`, `otel-format.ts`, `log.ts`, `relay.ts` (the client relay) | `withRootSpan`, `withSpan`, `log`, `relay`, `OtlpExporter` |

**Shipped:** `memo/`, `pipeline/` (`steps.ts`), `notify/`, `telemetry/`, `http/`, `adapters/`, `ports/`. Routing is not a module any more: Hermes decides (§Pipeline steps, Retired 2026-11-04). `devices/` is the `DeviceStore` port plus `adapters/sqlite-devices.ts`; `GET /v1/stats` is the read-only `StatsStore` port plus `adapters/sqlite-stats.ts`. The module and
file map of the code is in `AGENTS.md` §Layout.

Ports, each with a production adapter and an in-memory fake (shipped: `Transcriber`, `Speaker`, `Destination` (Hermes, the only one; `fakeDestination` answers `done`, kind `note`, two actions),
`Notifier`, `DeviceStore`, `StatsStore` (SQLite only, no fake), `AudioStore`, `AudioCombiner`, `Clock`, `DiagramRenderer` (Pele + resvg-js), `AssetStore` (reply asset files); `Ids` is unused).
`Destination.deliver({memoId, transcript, mode, threadId?}) → Delivery {ref, replyText, usage?, costUsd?, thread?, meta?}` with `meta = {kind, headline, actions}`. There is no registry: `compose()` chooses the one destination
from `HERMES_URL` + `HERMES_TOKEN` and records `act` in `degraded` when it is missing; under `IRIS_FAKES` it is `fakeDestination({sessionPerMemo: true})`.

### Memo state machine

```
receiving ──complete──> received ──> transcribed ──act──> acted ──notify──> notified (terminal)
any step ──error──> failed(step)   ──retry(from)──> <step>
typed memo:       created transcribed ──act──> acted ──> notified
mode transcribe:  received ──> transcribed ──notify──> notified   (no act)
```

- **Pipeline per mode:** `stepsOf(mode)` in `memo/memo.ts` is the pipeline for every memo: `ingest → transcribe → act → summarize → notify` for every mode but `transcribe` (`runsAct(mode)`), `ingest → transcribe → notify` for mode `transcribe`;
  a typed memo (`POST /memos/text`, created `transcribed`) starts at `act` (`notify` in mode `transcribe`). `nextStep`, `advance({state, step, mode})` and `stateBefore({step, mode})` read one transition table per mode; `stateBefore` throws
  `IllegalTransitionError` for a step outside the mode's pipeline. The state is the last finished step. The modes on the wire are unchanged (`auto|journal|hermes|tab|chat|transcribe`, stored as received); Hermes decides what the memo is, so only `transcribe` differs.
- **Waiting for Hermes:** `act` has a handler only when a `Destination` is composed. Without one the memo stays `transcribed` (a degraded start, `/health` lists `act`) and the runner drives it once the server runs with Hermes configured. A memo that stays `transcribed`
  is therefore either waiting for a configured Hermes or has no running runner; a memo that failed there is `failed(act)`.
- **Mode `transcribe` (Wave 17 S2):** the owner picks "just the transcript" up front. The steps it does not have are absent, not skipped: no `act` row on the timeline (`GET /memos/:id` `steps` holds `transcribe` and `notify`;
  the waterfall only draws rows that exist), `reply_text`, `summary`, `kind` and `actions` stay empty and the server needs no Hermes to finish the memo. The memo ends in the ordinary terminal `notified`, so `isResultReady`, `/result` and `memo.done`
  need no special case. `notify` announces the transcript clipped to a 60-code-point headline, the alert title is the generic "Iris" (no kind chip). A typed memo in this mode runs only `notify` and ends at once. A `threadId` with this mode is 400
  `bad_request` (a thread continues in Hermes, which this mode never reaches).
- **Old rows:** `routed`, `needs_route` and the step `route` are no longer produced (`summarize` and `summarized` are live); `STEPS` and `MEMO_STATES` keep them so old rows read. Migration 14 settled the open ones (§Data model). `isResultReady` is
  terminal or an old `needs_route`; `isDeletable` still includes `needs_route`.
- **Idempotent steps:** each step is keyed by `(memo_id, step, attempt)`. On
  boot and on every `complete`, the runner drives each non-terminal memo from
  its last finished step.
- **Timeouts:**

  | Step | Timeout |
  |-|-|
  | STT | 300 s |
  | Hermes | 180 s |
  | APNs | 10 s |

- **Retries (built):** a transient failure is retried in-process twice, after 2 s and then 8 s (three tries in all; the delays go
  through an injected `Sleep`, so tests never wait), before the step goes `failed`. Adapters mark a transient failure with a
  `TransientError` (`ports/transient.ts`, the one place that classifies: an HTTP 5xx, a timeout or abort, a connection error such as
  ECONNREFUSED / ECONNRESET / `fetch failed`); the runner decides. Everything else (4xx, validation, an off-schema answer, an explicit
  throw) fails at once. A `TransientError` is `before_send` when the request provably never reached the destination (connection
  refused, DNS) and `after_send` otherwise (a timeout, a reset, a 5xx, an unrecognised `fetch failed`: it may have been delivered).

  **A hang guard is not transient.** The idle watchdogs of Hermes (no response, or a stream gone idle, within the idle window) mean the downstream is wedged, so a retry would only
  wait out the same window again. They throw a plain error (`hangGuardFailure` in `ports/transient.ts`): the step fails after one window and `POST /retry` is the decision. A short request
  timeout that means "try again" (the 30 s Hermes session create) stays transient, as do 5xx and connection errors. The audio-door STT timeout (30 minutes, `timeoutMs` in the adapter) is a hang guard too: one window, then `hangGuardFailure`. The speech timeout (2 minutes) is not retried either: `/speech` is a request, not a step, and answers 503.

  | Step | Retried on |
  |-|-|
  | transcribe, notify | every transient failure |
  | act | `before_send` only: Hermes may already have run the turn after a timeout or 5xx, so those fail and `POST /retry` is the (human) decision |

  `stop()` (shutdown) during a backoff cuts the wait short and runs nothing more: the step stays `running`, not `failed`,
  and the next boot's `driveAll` re-runs it from `attempts` 1. Each try bumps
  `memo_steps.attempts`; while the runner waits to retry, the row stays `running` with `error` set to the failure it is retrying
  (clients read `status`, never `error != null`, as failure), and the error clears on success. No `memo.updated` event goes out for a
  retry (the event is per state change); `attempts` shows on the next event or detail fetch. Every try is its own `memo.<step>`
  span (attribute `attempt`) and each wait a `memo.retry_wait` span under the `memo` root, and each retry logs `step.retry`
  (`memo_id`, `step`, `attempt` = the try about to start, `delay_ms`, `error`). `POST /retry` still resets the row, so the re-run
  starts at `attempts` 1.
- **Retry rules:** `POST /retry` works on `failed` memos only and only for a step of the memo's pipeline (`stepsOf(mode)`); a retry from `act` posts a second turn into the same Hermes session (`act` is at-least-once).
  An old `failed(route)` memo counts as failed at `act` (`canRetryFrom`), so it retries from `act`.
- **Optional steps:** `summarize` is optional (`OPTIONAL_STEPS`). When it fails for good the runner calls `store.skipStep`: the step row stays `failed` (error and attempts kept), the memo moves `acted` → `summarized` without becoming `failed`, `notify` runs and the memo ends `notified` with `summary` null (`step.skipped` log, a `memo.updated` for step `summarize`). `POST /retry {from: "summarize"}` also resets such a `notified` memo (a failed `summarize` row) to `acted` and re-runs summarize and notify. Every other step fails the memo.
- **Retention:** audio is deleted 30 days after `notified`; rows are kept.

### Data model (SQLite, WAL, append-only migrations in `server/src/adapters/sqlite-migrations.ts`, `PRAGMA user_version`)

Shipped (Waves 5, 10 and 12). Step results are columns on `memos`, not a separate table.

| Table | Columns (key ones) |
|-|-|
| `memos` | `seq` (autoincrement), `id` (uuid, client-minted), `mode` (auto/journal/hermes/tab/chat/transcribe), `device` (authenticated device name), `state`, `failed_step`, `error`, `started_at`, `segment_count`, `audio_seconds`, `transcript`, `route` (legacy, null on new memos), `destination_ref`, `reply_text`, `summary_json` (agw `triage`'s summary, written by `summarize`), `kind` (Hermes' normalised kind, migration 14), `hermes_headline` (the headline of Hermes' iris block, ≤ 60 code points, migration 14; not on the wire), `actions_json` (tool names, migration 14), `thread_id` (the Hermes session the memo belongs to: set by `act`, or at creation for a memo that continues a thread; NULL before then), `done` (0/1), `favorite` (0/1), `archived_at` (nullable ISO), `deleted_at` (nullable ISO; the soft delete), `created_at`, `updated_at` |
| `segments` | `memo_id`, `idx`, `bytes`, `sha256`, `received_at`: PK (`memo_id`, `idx`) |
| `memo_steps` | `memo_id`, `step`, `status`, `started_at`, `finished_at`, `error`, `usage_json`, `cost_usd`, `attempts` (INTEGER NOT NULL DEFAULT 1: tries used, see Retries; on the wire as `attempts` ≥ 1): PK (`memo_id`, `step`); `POST /retry` deletes the rows from the step on, so the re-run counts from 1 |
| `devices` | `device` (PK, the token-map name), `name` (display label), `platform` (ios/macos), `apns_token`, `apns_env` (sandbox/production), `push_to_start_token`, `last_seen_at`, `updated_at` |
| `activity_tokens` | `memo_id` (PK, cascades), `token`, `updated_at` |
| `threads` | `id` (PK, the Hermes session id), `kind` (hermes; chat on old rows), `title` (the first ~60 characters of the first transcript, whitespace collapsed), `created_at`, `updated_at`, `last_memo_id`. The destination names the thread in its `Delivery` (`thread: {id, kind, title}`; Hermes: the session id, `hermes`, the first ~60 characters of the transcript); `act` persists what it gets, upserting the row and setting `memos.thread_id` in the transaction of `completeStep` (`patch.thread`; `thread_id` is an `act`-owned column). An existing thread keeps its kind and title and moves `updated_at` / `last_memo_id`. A retry from `act` clears `thread_id` when it is the memo's own session (equal to the memo id) until the re-run sets it again, and keeps it for a memo created to continue a thread (its `thread_id` is never its own id: `continuedThread` in `memo.ts`); the thread row stays. The migration backfilled one `hermes` thread per distinct `destination_ref` of an existing hermes memo. `GET /v1/threads` and `/v1/threads/:id` read it (§HTTP API); the queries sit behind the `ThreadStore` port (`adapters/sqlite-threads.ts`, composed into the memo store) |
| `memo_fts` | FTS5 virtual table, external content over the view `memo_search` (`seq`, `transcript`, headline = `summary_json.$.headline`; a malformed `summary_json` indexes as no headline), `content_rowid = seq`, tokenizer `unicode61 remove_diacritics 2`. Triggers on `memos` (insert, delete, update of `transcript` / `summary_json`) keep it in step; migration 7 backfills with `rebuild`. Read by `GET /v1/memos?q` only |
| `reply_artifacts` | One row per typed artifact of a reply (migration 17): `memo_id` (cascades), `id` (uuid, the asset id, never reused), `kind` (show/doc), `artifact_index` (position among the reply's fences of that kind), `title` (nullable), `format` (markdown/html, docs only), `bytes`: PK (`memo_id`, `id`). The bytes are files next to the Mermaid ones. Written and replaced exactly like `reply_assets` (§Reply artifacts) |
| `reply_assets` | One row per rendered file of a reply's Mermaid blocks (migration 11): `memo_id` (cascades), `id` (uuid, never reused), `block_index`, `format` (svg/png), `scheme` (light/dark), `width`, `height` (points): PK (`memo_id`, `id`). The bytes are files under `<IRIS_DATA>/assets/<memo_id>/<id>`. Rows are written only by the commit of the reply they were rendered for (or the backfill). `memos.reply_assets_failed` (migration 13) marks a reply whose Mermaid blocks all failed to render (§Reply assets) |
| `route_decisions` | History of the retired routing, kept for old memos and never written: `id`, `memo_id` (cascades), `created_at`, `source`, `destination`, `tab`, `confidence`, `model`, `cost_usd`, `reason`, `outcome`, `prefix_words`. Nothing reads it |

**Indexes.** Besides the keys, `memos(state)`, `memos(kind)`, `memos(thread_id)`, a partial `memos(deleted_at)`, `route_decisions(memo_id, id)`, and (one migration, for the stats reads' `>=` filters) `memos(created_at)` and `memo_steps(started_at)`.

**Hermes decides (migration 14, Wave 21 S1).** The 14th entry (`PRAGMA user_version` 14) adds `memos.kind` (TEXT, the normalised kind Hermes reported), `memos.hermes_headline` (TEXT, the headline of its block), `memos.actions_json` (a JSON array of tool names, NULL before `act`) and the index `memos_kind`. It also settles the memos the routing left behind: every open `needs_route` memo (`done = 0`, not soft-deleted) becomes `failed` with `failed_step = 'act'` and the error `parked before routing moved to Hermes`, plus a `memo_steps` row `act`/`failed` with that error (`started_at` = `finished_at` = `updated_at`), so the owner retries it from `act`; `routed` becomes `transcribed` (`summarized` is a live state again and is left alone). `route_decisions` stays as history and is never written; `memos.route` stays, null on new memos. `completeStep` writes `patch.kind`, `patch.hermesHeadline` and `patch.actions` (as JSON), and `summarize` writes the summary; `resetForRetry({id, from})` (failed memos only) clears the data columns of `from` and every later step of the full timeline: `transcribe` clears `audio_seconds` and `transcript`, `act` clears `destination_ref`, `reply_text`, `kind`, `hermes_headline`, `actions_json`, plus `thread_id` and the reply assets, and (it being a later step) `summarize` clears `summary_json`. Steps and states from before the change (`route`, `routed`, `needs_route`) stay in `STEPS` and `MEMO_STATES` so old rows still read.

**Memo flags and soft delete (Wave 13).** One append-only migration (the last entry) adds `done`, `favorite` (`INTEGER NOT NULL DEFAULT 0`), `archived_at`
and `deleted_at` (nullable ISO text, like the other time columns) and a partial index on `deleted_at`. None of them touches the state machine or the runner:
a flag is a user annotation, `updated_at` moves with it. `archived_at` is stamped once (archiving an archived memo keeps the first time). A delete is a
**soft delete**: `DELETE` stamps `deleted_at` (allowed in a settled state or `receiving`, never mid-pipeline), the memo stays readable through `GET /memos/:id` (`/audio` and `/speech` are 409 `bad_state` like the other live-only routes) and `POST /restore` clears it, until
`purge_at = deleted_at + PURGE_AFTER_MS` (10 minutes, `memo/memo.ts`, the one definition). The **purger** (`memo/purge.ts`, built from the store, the
audio store, the speech cache and the injected `Clock`) sweeps on boot and every 60 s (`PURGE_SWEEP_MS`): for each memo with `deleted_at <= now -
PURGE_AFTER_MS` it removes the audio files (segments and the combined recording, `AudioStore.remove`), the speech files (`SpeechCache.remove`) and the reply asset files (`AssetStore.removeAll`) first,
then the rows (`MemoStore.purge`: `memos`, which cascades `memo_steps`, `segments`, `route_decisions`, `reply_assets`, `reply_artifacts` and `activity_tokens`; the FTS triggers drop the index
entry) and logs `memo.purged` with `memo_id`. Files before rows, so a failed removal (`memo.purge_failed`) leaves the memo for the next pass instead of
orphaning files. A thread whose `last_memo_id` was the purged memo points at its newest remaining memo, and a thread left with no memos is deleted.
The sweep runs behind the shutdown drain (`purger.stop()` / `idle()` next to the runner's). Reads: a soft-deleted memo is not in `items` of
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

Planned for R3, not built: `memos.target_tab` / `language`. Device tokens are not stored: the token map lives in `IRIS_DEVICE_TOKENS`.

### HTTP API (`/v1`, bearer = device token; `/health` is public)

Shipped; the authoritative list is `contracts/manifest.json` and the table in `AGENTS.md`.

| Method + path | Purpose |
|-|-|
| `POST /v1/devices/register` | `{name, platform, apnsToken?, apnsEnv?, pushToStartToken?}`; upsert by the authenticated device |
| `POST /v1/telemetry` | The client span/log relay (§8): `{resource: {serviceName: iris-ios\|iris-macos, deviceName, appVersion}, spans, logs, dropped}`. 202 `{accepted: {spans, logs}}`; 413 over 256 KiB; 400 for a schema violation, a timestamp that is not a date, or more than 500 spans and logs together; 503 when the relay is not wired. The records are exported in the background, so an unreachable collector never changes the answer |
| `POST /v1/memos` | `{id, mode, startedAt, threadId?}`, idempotent. `threadId` continues that thread (404 when unknown; see Threads below); a replay naming another thread is 409 |
| `POST /v1/memos/text` | `{id, mode, startedAt, text, threadId?}`: a typed memo. `text` is trimmed, 1 to 20 000 characters, counted as Unicode code points (else 400). A missing or unknown `mode` is 400. Created directly in `transcribed` with `transcript = text` and driven from `act`: 202 + memo, on a replay too. Idempotent by id: the same body returns the memo, another body (a different `threadId` included), another device or a recorded memo with that id is 409 `conflict`; an unknown `threadId` is 404 |
| `PUT /v1/memos/:id/segments/:n` | Raw m4a bytes, idempotent by `n` (same sha → 200, different → 409) |
| `POST /v1/memos/:id/complete` | `{segmentCount}`. A 422 lists the missing indices |
| `PUT /v1/memos/:id/activity-token` | The Live Activity push token for this memo (204) |
| `POST /v1/memos/:id/retry` | `{from: Step}`, only for a `failed` memo (else 409; the one exception is above), and only a step of the memo's pipeline (`stepsOf(mode)`; 400 `bad_request` otherwise, including `from: "transcribe"` on a typed memo, `act` on a mode `transcribe` memo, and the retired `route`). An old `failed(route)` memo counts as failed at `act`, so it retries from `act`. Also 202 for a `notified` memo with `from: "summarize"` when its `summarize` step failed |
| `GET /v1/memos?limit&cursor&q&state&favorite&archived&kind&thread` | History, paged, newest first: `{items, nextCursor}`. `q` (≤ 200 characters) searches transcript and summary headline (see Data model); `state` (any memo state) filters exactly; `kind` (a free string) keeps the memos of that kind, exact after the same normalisation as the stored kind (trim, lower-case, cut to 24 code points; text with nothing left matches nothing); `thread=true` keeps the memos of a conversation: those whose thread (Hermes session) has at least two live memos, i.e. a continued one (every acted memo has a session of its own, so "has a `thread_id`" would match nearly all); `favorite=true` keeps the favorites, `archived=true` lists **only** archived memos (without it archived memos are hidden); `favorite`, `archived` and `thread` accept only `true` (omit them to switch off); all combine, an unknown `state` is 400. Soft-deleted memos are never listed. There is no `route` filter, no `pinned` and no `pinnedTruncated`; an old `needs_route` memo is an ordinary item at its seq position |
| `GET /v1/memos/:id` | Memo + step timeline; `partialReply {attempt, seq, text}` while `act` has streamed visible text (omitted otherwise). Also a soft-deleted memo (with `deletedAt` / `purgeAt`, so undo works); 404 after the purge |
| `PATCH /v1/memos/:id` | `{done?, favorite?, archived?}`: booleans, at least one; an empty body, an unknown key or a non-boolean is 400 (the route rejects unknown keys itself, Elysia strips them before validation). 200 memo; 404 unknown; 409 `bad_state` on a soft-deleted memo. Allowed in every pipeline state. Publishes `memo.updated` |
| `DELETE /v1/memos/:id` | Soft delete: 200 memo with `deletedAt` and `purgeAt`. Only settled memos (`notified`, `failed`, and an old `needs_route`) and a memo still `receiving` (a cancelled take: the client creates the memo at its first closed segment), else 409 `bad_state`. A deleted `receiving` memo takes no more segments and no `complete` (both 409 `bad_state`, like every write to a deleted memo), so the pipeline never starts; a segment write still in flight when the delete lands is refused and its file removed right after the write (no row names it; the segments already recorded stay for a restore within the undo window), the purger removes the rest. A repeat is idempotent (200, the first `deletedAt`, no event); 404 unknown. `retry` on a deleted memo is 409 `bad_state`. Publishes `memo.updated` |
| `POST /v1/memos/:id/restore` | Undo: 200 memo (`deletedAt` cleared, flags kept); 409 `bad_state` when the memo is not deleted; 404 once it is purged or past `purgeAt`. Publishes `memo.updated` |
| `GET /v1/memos/:id/result?wait=<s>` | Long-poll until result-ready (≤ 600 s) |
| `GET /v1/threads?limit&cursor` | `{items: Thread[], nextCursor}`, newest `updatedAt` first; `Thread = {id, kind, title, createdAt, updatedAt, lastMemoId}`. The cursor is the last row's `(updated_at, id)`, so it stays valid as threads are added or updated. A malformed cursor is 400. `Thread.kind` stays on the shape (`hermes`; `chat` on old rows) but is no longer a filter |
| `GET /v1/threads/:id` | `{thread, memos, messages}`: the memos that ran in the thread (oldest first) and the conversation built from them, `messages: [{memoId, role: user\|assistant, content (markdown), createdAt}]`: per memo its `transcript` (`user`, dated by the memo's `createdAt`) and its `reply_text` (`assistant`, dated by the end of its `act` step; omitted while empty). Iris's own record: Hermes is not consulted, so the response never depends on it. Read in a fixed number of queries (the thread, its memos, the `act` finish times), however long the thread is. Unknown thread 404 |
| `GET /v1/memos/:id/audio` | The concatenated audio for the scrubber (`Range`); 409 `bad_state` for a soft-deleted memo |
| `GET /v1/memos/:id/speech` | TTS of the speech-ready variant of the answer (below), cached as an mp3; 409 `bad_state` for a soft-deleted memo |
| `GET /v1/memos/:id/assets/:assetId` | One rendered file of a reply's Mermaid block (ids from the memo's `replyBlocks`): `image/svg+xml` (with `content-security-policy: default-src 'none'; style-src 'unsafe-inline'`) or `image/png`; or a reply artifact (ids from `replyArtifacts`): `application/json`, `text/markdown; charset=utf-8` or `text/html; charset=utf-8` (html with `content-security-policy: sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data:`; §Reply artifacts), `cache-control: private, max-age=31536000, immutable` (an id is never reused), `x-content-type-options: nosniff`; 404 for an unknown memo or asset, 409 `bad_state` for a soft-deleted memo, 503 without media |
| `GET /v1/events` | SSE: `ready`, `memo.updated`, `memo.done`, and while `act` runs `memo.delta` `{id, attempt, seq, text}` and `memo.activity` `{id, attempt, tool}` (for the Mac and the foreground iOS app) |
| `GET /v1/stats?days=<n>` | `days` 1..365, default 30, else 400 `bad_request`. `{days, from, to, perDay: [{date, kind, count}], perWeek: [{weekStart, count}], stepMedians: [{step, kind, medianMs, samples}], costPerKind: [{kind, costUsd, memos}]}`. Read-only aggregates over `memos` (by `created_at`) and `memo_steps` (both filter columns are indexed); no table of its own, no spend; 503 when the app is composed without a `StatsStore`. The window is the last `days` **local days of the server** (today included, `from`/`to` are `YYYY-MM-DD`); `date` and Monday-start `weekStart` use the same zone, and the first week only counts the days inside the window. `kind` is the memo's kind (§Pipeline steps, act) and `null` for a memo with none (mode `transcribe`, a failed memo, an old one); `perDay` and `costPerKind` are ordered by kind, null first. `stepMedians` is the baseline of the memo detail waterfall's faster/slower hint, **per step and kind**: `done` step records whose `started_at` is in the window, grouped by step and the memo's kind, in pipeline order (`STEPS`, old steps included) then kind, null first (integer ms; even counts average the two middle values and round, no other interpolation; a pair without samples is absent). `samples` is the n behind each median. **The client owns the minimum-n threshold**, the server does not send a `minSamples`: the threshold is a presentation choice (a hint wants more evidence than a plain number, and it may differ per surface), changing it must not need a server deploy or a contract change, and the server stays a plain aggregate that reports n honestly. `costPerKind` sums `memo_steps.cost_usd` per kind (the `act` row carries the Hermes turn's cost), `memos` counts the memos once. The memo detail waterfall compares its step durations to `stepMedians`. Day bucketing and medians run in the adapter, not with SQLite's `localtime`, so the window and the days share the process time zone |

A separate route rather than a `text` field on `POST /v1/memos`: that route answers 201/200 for a memo that is still `receiving` and waits for segments, a typed memo is complete on arrival and its replay must compare a body, so sharing the handler would branch every line of it. A typed memo has no ingest or transcribe row in its timeline. The memo shape carries `typed: true` for a typed memo and omits it for a recording (one predicate, `isTyped` in `memo.ts`: past `receiving` with no segment count; `GET /memos/:id` reports `segmentCount` 0 there, so clients read `typed`). `POST /retry` from `transcribe` on a typed memo is 400: the text is its only transcript. `GET /audio` on a typed memo is 409 `bad_state` (no recording); `/speech` works as for any memo.

The memo shape always carries `done`, `favorite` and `archived` (booleans; `archived` is `archived_at IS NOT NULL`, the time stays server-side) and, only while the
memo is soft-deleted, `deletedAt` and `purgeAt` (ISO, 10 minutes apart); both are omitted, never null, otherwise. A flag change, a delete and a restore
publish the existing `memo.updated` SSE event (same payload: `id`, current `state`, `step: null`); the client refetches the memo. The event is internally
marked `flagChange` (not on the wire): `GET /events` does not follow it with `memo.done`, and the Live Activity binding ignores it, so a
swipe never re-fires a notification or a result-ready handler.

**Threads.** A thread is a Hermes session (`threads` row; `kind` is `hermes` for every new one, `chat` only on rows from before the modes folded into one). `threadId` on either create route continues one: the service answers 404 for an unknown thread, 409 `destination_unavailable` while it is composed without Hermes (`hermes: false`; the turn could only fail at `act`, so create refuses it and stores nothing; a replay of an existing memo is judged by its stored thread instead) and 409 `conflict` for a replay whose `threadId` differs (`continuedThread`: a memo's own session, equal to its id, is not a continuation). The memo is stored with that `thread_id`, and `act` delivers into the thread's session (`Destination.deliver({threadId})`: the Hermes adapter skips the session create), one turn at a time per thread (a keyed queue in the `act` handler: a second memo for the same thread waits for the first turn's reply instead of failing; different threads do not wait for each other. The wait is bounded at 30 minutes, the size of a hang guard, since a turn has an idle watchdog but no wall-clock cap: past it `act` fails with `KeyedQueueTimeout` (`thread <id> is busy: waited 1800000 ms behind memo <id>, which has not finished`) and the task never runs, `POST /retry` queues it again. The line stays consistent: the failed waiter keeps its place until the stuck turn ends, so a later memo still waits for that turn, and the stuck turn's eventual completion changes nothing for anyone. A turn that has started is never cut off. `memo/keyed-queue.ts` takes `maxWaitMs` and an injected cancellable sleep: the timer is cleared as soon as the turn ahead finishes, so a served waiter leaves nothing pending). A waiter parked on that queue does not hold a `driveAll` slot: the act handler passes the runner's `whileWaiting` to the queue, which wraps only the wait behind another turn (a turn that starts at once never calls it); the runner gives the memo's slot back for that wait and takes one again, queueing behind whoever holds it, before the waiter delivers, so `driveAll` still runs at most three memos at once and an unrelated memo is never stuck behind a parked thread. Drives outside `driveAll` (HTTP create, retry) hold no slot, so `whileWaiting` is a plain await there. Every turn of a thread re-sends `system_message` (§Pipeline steps, act). The upsert moves the thread's `updated_at` and `last_memo_id` as for any `act`. The conversation is Iris's own data (`threadMessages` in `memo.ts`, built from the thread's memos in `seq` order); Hermes keeps its session but its transcript is never read.

The memo shape carries `kind` (the normalised kind Hermes reported) and `actions` (tool names, deduplicated, ≤ 12); both are omitted, never null, when absent or empty. `route` stays on the shape as a nullable field no step writes. `routeReason` and `routeSuggestion` are gone.

**Planned, not built:** the `targetTab` / `language`
fields of `POST /v1/memos`.

Every request and response body has a schema and a fixture in `contracts/`.
Elysia routes declare TypeBox schemas, and `make check-contracts` asserts that
the exported JSON Schema matches `contracts/schema`.

### Pipeline steps

Three runner steps: `transcribe` (includes the concat below), `act` and `notify`. `act` runs for every mode but `transcribe` (`runsAct(mode)`, `memo/memo.ts`). The timeouts
follow `agent-limits.md` (idle watchdogs and 30-minute hang guards, not the budgets sketched earlier). Transient failures are retried automatically (§Memo state
machine, Retries); retention (audio deleted 30 days after `notified`) is not built. Recover a `failed` memo with `POST /retry`.

1. **concat:** `ffmpeg -f concat` over the segments → decode → mono 16 kHz
   AAC. Records `audio_seconds`.
2. **transcribe:** `POST <audio door>/audio/transcriptions` (`AUDIO_DOOR_URL` carries the `/v1`).
   - Fields: `model=voxtral-mini-transcribe-3-0`, `language` (the device hint or
     auto), and `context_bias` (repo names, recent thread titles).
   - Header: `Authorization: Bearer <AUDIO_DOOR_TOKEN>`; the answer carries `agw-run-id`, logged and set on the span as `agw.run_id`. A 401 is final.
   - The door handles chunking up to about 2 h. A 413 is terminal.
3. **act:** registered only when a `Destination` is composed (`HERMES_URL` + `HERMES_TOKEN`, or the fake); without one the memo waits at `transcribed` and `/health` lists `act` in `degraded`.
   The handler calls `destination.deliver({memoId, transcript, mode, threadId?})` with the raw transcript (no prefix is cut any more; `threadId` only for a memo that continues a thread,
   `continuedThread(memo)`), through the keyed queue per thread (§HTTP API, Threads), syncs the reply assets (§Reply assets) and returns the patch
   `{destinationRef, replyText, thread, kind, hermesHeadline, actions}`; the last three come from `Delivery.meta` (`{kind: string|null, headline: string|null, actions: string[]}`; no meta →
   `null`, `null`, `[]`). `memo.route` is never written by a step (null on new memos). Hermes's block never writes `summary`: that is the next step's.

   **The Hermes turn** (`adapters/hermes.ts`). A new session is `POST /api/sessions {id: memoId, source: "iris"}` (201/409 = OK); a continuation skips it. Every turn, new or continued, is then
   `POST /api/sessions/:id/chat/stream {message: transcript, system_message}` and the final assistant text is collected from the SSE. `system_message` is Hermes' per-turn ephemeral system prompt (appended to that
   turn, never stored), so it is sent on every turn. It is `IRIS_SYSTEM_MESSAGE`, exported from the adapter:

   > This turn comes from Iris: the message is a transcript of the owner's voice memo (German or English, speech-to-text errors likely). Load skill_view('iris') and follow it: decide what the memo is, act with your skills (a side effect only when the memo asks for one), and end your reply with exactly one ```iris block.

   The modes of an older app build add one line, `The owner picked: Chat.` / `Journal.` / `Tab.` (`systemMessage(mode)`); `auto` and `hermes` add nothing, and the thread kind is `hermes` either way.
   Hermes rewrites unknown session sources: `_normalize_session_source` keeps only its own allow-list (`api_server`, `browser`, `cli`, `telegram`, `discord`, `slack`, `desktop`, `dashboard`), so `iris` is stored as `api_server` there;
   the value is still sent, which works unchanged if Hermes widens its list.

   **The `iris` block contract.** Hermes ends its reply with one fenced block tagged `iris`: JSON `{kind, headline}` (strings; the spoken line and the summary stay with agw `triage`, `summarize`). `parseIrisBlock(reply)` is lenient and never fails the step:
   - the **last** ```` ```iris ```` fence wins (an opening fence, `iris`, a newline, the JSON, a closing fence); extra keys (an old `spoken` too) are ignored;
   - the fence and the whitespace before it are **stripped from `reply_text`**, also when the block is invalid (a machine block is never the answer);
   - `kind` goes through `normalizeKind` (trim, lower-case, cut to 24 code points, empty → null); `headline` is trimmed and clipped to 60 code points (`HEADLINE_MAX`, ellipsis; null when blank) and stored as `hermes_headline`, `notify`'s fallback when triage has no summary;
   - no fence, bad JSON or a missing key gives `meta: null` and the adapter logs `hermes.meta_invalid {memo_id, reason}` (`reason`: `missing_block`, `invalid_json` or `invalid_shape: <paths>`; never the content). The memo still completes, with no kind and no Hermes headline.

   **`actions`.** The SSE `tool.started` frames of the turn carry `tool_name`; the adapter collects names only (`actionOf`): the tool's `tool_name`, except `skill_view`, where it is the loaded skill (`args.name`, a string only, `<plugin>:` prefix and path cut to the last segment; the `iris` skill that opens every turn and a call without a usable name add nothing; hermes-agent `tools/skills_tool.py` `skill_view(name, file_path, …)`). No other argument is read. `normalizeActions` trims, drops blanks, deduplicates (first seen) and keeps at most 12 (`ACTIONS_MAX`).
   They are stored in `memos.actions_json` and shown as what Hermes did.
4. **summarize:** agw host `POST /triage {destination, transcript, reply}` with `destination` always `hermes`, the raw transcript and `memo.replyText` (the reply after the iris block is cut, never tool traffic or `actions`); the host cuts each at 4000 characters and owns the prompt. It answers the flat
   `{headline (≤60), detail (≤240), spoken (≤300 characters, the cap standing for two sentences), model, attempts, latencyMs, usage}`, stored as `summary` (`costUsd` null is stored as null). The step is optional (§Memo state machine, Optional steps): without a summarizer (`AGW_URL` + `AGW_API_SECRET` unset, `/health` lists `summarize` in `degraded`) or when triage fails for good, it fails, is skipped and the memo goes on to `notify` with `summary` null.
5. **notify:** announces `memo.summary.headline`; without a summary the headline is `memo.hermes_headline`, and without that the transcript, whitespace collapsed, clipped to 60 code points (`transcriptSummary`: detail 240, `spoken` empty). A memo that never reached either (mode `transcribe`, a failed `summarize` and a Hermes reply with no valid block) is announced the same way.
   - a Live Activity `update` (priority 5) for each phase change (`processing`, `failed`; an old `needs_route` state maps to `processing`), then for a done take the announcing `update` (priority 10, below) plus a final
     `end` (priority 10) with the result content state and `dismissal-date` = now + 15 min, no alert, stamped one second after the done update; the content state carries `routeChip` = the memo's `kind` capitalised (≤ 30 code points; no chip when the kind is null).
     **A final `update` (phase done, priority 10) sent just before the `end` carries the announcement (owner 2026-11-05, after the first real Live Activity proof showed the end plus a banner, "doppelt gemoppelt"; moved from the `end` to the `update` in Issue 223 because Apple documents the alert sound for `update` only and the device played none for an `end` alert, docs/research/2026-11-07-live-activity-end-sound.md):** `aps.alert` = `{title: kind chip or "Iris", body: headline (≤ 200), sound: "default"}`, which lights the device and plays the sound
     (Apple, [Starting and updating Live Activities with ActivityKit push notifications](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications): an optional `alert` with `title`, `body` and `sound` "to light up their device and display the expanded presentation on devices that support the Dynamic Island or a banner on devices that don't"; the
     docs' examples put `sound` inside `alert`; [Generating a remote notification](https://developer.apple.com/documentation/usernotifications/generating-a-remote-notification) lists the alert keys and `default` as the system sound; the [HIG](https://developer.apple.com/design/human-interface-guidelines/live-activities) says alerts play the notification sound by default and not to pair a push notification with a Live Activity for the same update).
     Device-verified only: the sound of an `alert` on that `update` and the Notification Center entry (a developer report says none appears on iPhone; the accepted tradeoff is that such a memo has none, History keeps it);
   - one alert push (priority 10, `mutable-content: 1`, `category: MEMO_DONE`, the only category, `thread-id: memo`, `apns-collapse-id` = memo id, a `memo` id in the custom payload, titled with the same kind chip or "Iris" when there is none) **only for a memo without a Live Activity token** (every typed memo, a take whose activity never started) or when the done update is refused for good (the activity is gone: 410, BadDeviceToken); a transient failure of either push throws and the retry sends both again;
   - SSE `memo.done`;
   - a `log` stand-in when APNs is not configured.

**Retired 2026-11-04 (Wave 21 S1).** Iris used to classify each memo itself: a spoken prefix (journal, hermes, `tab <name>`), then agent-workflows `decide` (confidence ≥ 0.8 routed, otherwise the memo parked at `needs_route` until
the owner answered in the app with `POST /route`), then one of three destinations (a journal note in the brain inbox, a herdr/hc tab, Hermes, plus a chat mode with a no-side-effects prompt) and an optional `summarize` (`triage`) step (the step stayed: owner 2026-11-04, triage writes the better summary).
It went because 16 of 27 `auto` memos in production parked at `needs_route` on low `decide` confidence (0.25 to 0.77), and Hermes already routes with its skills. The full design (the `routing/` module, `Decider`, `Herd`, the journal and herdr adapters,
`route_decisions`, the answer API and the pane queue) is in git history before the Wave 21 S1 commit.

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
  `summary.spoken` + "Details on screen." (the first whole sentences of the cleaned reply when there is no summary, e.g. Hermes sent no `iris` block). Measured on the cleaned
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

**Orphan sweep.** A crash between a commit and its prune (or between a render and its staging) leaves files that no row names. `ReplyAssets.sweep`, started next to the backfill in `index.ts`, lists the memo directories under `<IRIS_DATA>/assets/` (newest change first, stat-ed 32 at a time; a directory that vanishes is skipped silently, one that cannot be stat-ed (EIO, EACCES) is skipped and logged as `reply.sweep_failed` with its name, so it never hides the healthy ones; at most `SWEEP_LIMIT` = 200 examined per start) and, per directory and inside the memo's queue, removes every file that is not named by the memo's rows and not held by an in-flight attempt (files staged with the store and not yet settled). A directory whose memo no longer exists is swept empty. It logs `reply.orphans_removed` (memo id, count, file names) and `reply.sweep` (examined, removed, skipped: the directories the limit left for a later start, null when the listing itself failed), skips a directory that fails (`reply.sweep_failed`) and stops after the current memo on `stop()`.
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

### Reply artifacts: `iris-show` specs and `iris-doc` documents

Two more top-level fence kinds ride the lifecycle of the Mermaid assets (`ReplyAssets.sync` stages them with the same `stageReplyAssets`, `completeStep` replaces the rows with the reply, `resetForRetry` from `act` drops them, the purge cascades the rows and `removeAll` the files, `pruneToRows` and the orphan sweep keep the files of `replyArtifacts`). The fence **stays in `reply_text`** as the anchor, like Mermaid. `extractFences` (`memo/fences.ts`, re-exported by `reply-assets.ts`; the same CommonMark rules as Mermaid, `lang` = first word of the info string lower-cased, `info` = the rest) feeds both extractors. `memo/reply-artifacts.ts` (`extractReplyArtifacts`) validates:

- ```` ```iris-show ````: the body is one JSON spec, a zod 4 discriminated union on `type`, every object strict (unknown keys reject). `table` `{title?, columns (1..12 × 1..80 chars), rows (0..200, each as long as columns; string/number/boolean/null cells)}`; `chart` `{title?, kind: bar|line|area|pie, x (1..100 strings or numbers), series (1..8 of {name 1..80, values: number|null, as many as x}), unit? ≤ 16}`, a pie has exactly one series; `stat` `{title?, items (1..8 of {label 1..80, value string|number, unit? ≤ 16, delta? number, hint? ≤ 200})}`; `list` `{title?, ordered?, items (1..50 of {text 1..500, detail? ≤ 1000})}`; `callout` `{tone: info|success|warning|danger, title?, body 1..2000}`; `title` is 1..200 chars everywhere, numbers are finite. Raw body at most 64 KiB (UTF-8 bytes, checked before `JSON.parse`). Stored as `JSON.stringify(parsed spec)`. The schema is exported as the contract `artifacts.show-spec` (`z.toJSONSchema`, `contracts/schema/`, manifest section `artifacts`); the zod schema and the exported one are tied by a test over the fixtures.
- ```` ```iris-doc title="…" format=markdown|html ````: a standalone document stored as is. The info string is `key=value` pairs (a value optionally in double quotes, no escapes); keys `title` (1..200 chars) and `format` (default `markdown`); an unknown key or format, a repeated key or a malformed pair is invalid. Body at most 200 KiB (UTF-8 bytes); an empty or whitespace-only body is invalid.

**An invalid artifact stays a code block** and logs `reply.artifact_invalid` `{memo_id, kind, index, reason}` with `reason` one of `too_large | bad_json | bad_spec | bad_info | empty`; `bad_spec` adds `issues` `[{path, code}]` built from zod's `path.join(".")` and `code` only (never content, never zod messages). At most 12 artifacts per kind per reply (`MAX_ARTIFACTS`); more log `reply.artifacts_capped` `{memo_id, kind, total, cap}` and are ignored. `index` is the zero-based position among the reply's fences **of that kind**, invalid ones counted, so the n-th `iris-show` fence is index n whether or not earlier ones were valid. An artifact whose file cannot be stored logs `reply.store_failed` `{memo_id, kind, index}` and is dropped alone. Artifacts never set the failed marker and **are not backfilled**: a reply from before them keeps its fences as code blocks (the boot backfill is Mermaid-only).

Wire: `Memo.replyArtifacts` (**omitted** when empty) is `[{index, kind: show|doc, title?, format?, assetId, bytes}]`, sorted `show` before `doc`, by `index` within a kind; `title` and `format` are omitted when absent (`format` only on a doc). The file is `GET /v1/memos/:id/assets/:assetId` (the route looks the id up as a Mermaid asset, then as an artifact): `application/json` (show), `text/markdown; charset=utf-8` or `text/html; charset=utf-8` (doc), the usual `nosniff` and immutable cache; an HTML document also carries `content-security-policy: sandbox; default-src 'none'; style-src 'unsafe-inline'; img-src data:`. The read model adds a `reply_artifacts_json` subselect to `MEMO_SELECT` (rows that no longer parse drop the artifacts with `memo.reply_artifacts_invalid`). Speech: an artifact fence is not read; the speech says its title (the spec's `title`, the info-string title) after "a visual" / "a document" ("eine Darstellung" / "ein Dokument"), the phrase alone without one. The live stream shows the artifact fences (only the routing ```` ```iris ```` block is held back).

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
| agent-workflows host | `http://127.0.0.1:7791`, `Authorization: Bearer <AGW_API_SECRET>` (`op://mini/agent-workflows/API_SECRET`), `x-agw-purpose: iris`, `x-agw-caller: iris`, `x-agw-project: iris`, no redirects. Synchronous `POST /triage` (the `summarize` step; `decide` is no longer called); the flat answer carries `model`, `latencyMs`, `usage` (`costUsd` null when any attempt is unpriced). Every response, errors included, has `agw-run-id`. 400, 401 and 502 `INVALID_OUTPUT` are final, 500 and 503 transient. `GET :7791/health` is `make verify`'s downstream check | `agent-workflows/packages/capabilities/README.md` (triage), `packages/host/README.md` (auth, cancel, idempotency) |
| Hermes | Bearer from `op://hermes/gateway/api-server-key`; `POST /api/sessions {id, source: "iris"}` (201/409 = OK), `POST /api/sessions/:id/chat/stream {message, system_message}`, SSE named events. Tool names for `actions` come from the SSE event `tool.started`, data field `tool_name` (hermes-agent `gateway/platforms/api_server.py`, `_tool_progress`, lines 3115-3127); only names are read: the tool name, or for `skill_view` the skill in `args.name` | `argo/apps/api/src/lib/hermes-upstream.ts`, hermes-agent `gateway/platforms/api_server.py` |
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
| `AGW_URL`, `AGW_API_SECRET` | The agent-workflows host (`http://127.0.0.1:7791`) and its bearer (`op://mini/agent-workflows/API_SECRET`). Both register `summarize` (agw `triage`); unset, the step is skipped and `summarize` is `degraded` |
| `HERMES_URL`, `HERMES_TOKEN` | Hermes endpoint and bearer. Both register `act`, the one destination; unset leaves every memo waiting at `transcribed` and `act` in `/health` `degraded` |
| `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` | APNs credentials |
| `IRIS_FAKES` | Boots every downstream port from in-memory fakes (`make e2e`); `degraded` then lists `fakes`. Never set in production (`launch.sh` refuses) |
| `OTEL_*` | Telemetry export |

`env.ts` parses only these. `HERDR_SOCKET`, `HC_BIN`, `HC_SOCKET` and `BRAIN_DIR` were removed with the routing (Wave 21 S1). `/health` `degraded` lists
only `otel` (no OTLP endpoint), `fakes`, `device-tokens` (empty map), `transcribe`, `act`, `summarize` and `speech` (a missing port); APNs falls back to the log notifier without being listed.

**Iris is a Hermes client only (Issue 403).** It makes no call to the software factory and sends no factory push; a voice request reaches the factory through Hermes, and the factory's own surfaces (asks, answers, health) live in the Console. The earlier `/v1/factory` routes, the decision-ask watcher, the Decisions tab and `FACTORY_URL` / `FACTORY_TOKEN` are removed; migration 16 drops `factory_ask_pushes`.

New refs go into `dotfiles-private/headless.refs`.

## 4. iOS app

### Targets

| Target | Contents |
|-|-|
| `Iris` | The app: composition root, scenes, App Intents, `AppShortcutsProvider`, notification delegate |
| `IrisWidgets` | `ControlWidget` (record), the Live Activity (`ActivityConfiguration` with Lock Screen + Dynamic Island) |
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

**One conversation** (issue 680, the owner reversed the PRD's "no full chat client" on 2026-11-10). One rule on both platforms, `Memo.isConversation` (IrisCore): a non-deleted
Hermes memo is a conversation as soon as it exists, before `act` too; a transcribe-mode or deleted memo is a document and keeps `MemoDetailView` (transcript bubble with the
player, Details, Retry). A History row of any Hermes memo pushes `ThreadView` anchored at that memo (`ThreadModel(memo:)`); the Mac detail lays the same memos out as a chat
(`MacMemoDetailModel.isChat`). The row's thread marker stays for a memo that continues another memo's session (`Memo.continuesThread`, `threadId != id`). The turns come from
IrisCore's `ConversationTimeline` (`entries(of: ThreadDetail)` / `entries(of: Memo)`): a user turn per memo with a transcript, an assistant turn per reply, and for a memo that
has no reply yet either a **pending** turn (the step dashes from the memo's state, a caption) or, for `failed`, the server's error. The app maps an entry to IrisUI's
`ConversationTurn` (Mermaid assets, step progress, captions) and both platforms render it with `ConversationTurnList` (`Style.phone` / `Style.mac`); on the phone the last turn of
each memo carries a **Details** button that opens `MemoDetailsSheet` for that memo: kind chip, day · time · cost, the error, the recording's player and Play reply, the step
waterfall (expanded on a failed memo) with [Retry from step], copy rows, the actions line, the ids, and the Retry bar (`MemoDetailsSection` is shared with `MemoDetailView`).
`ThreadModel` loads `GET /v1/threads/:id` once the anchor has a `threadId`; before that it refreshes the anchor (`GET /v1/memos/:id`) and shows its own turns, which a thread
that cannot be read also leaves on screen. A `memo.updated` event for the anchor or any memo of the thread bumps History's revision of it, the screen reloads, and the pending
turn turns into the answer in the same place with a short fade and height animation (none under Reduce Motion). **Streaming** (the owner reversed the 2026-10-28 "no token stream" on 2026-11-10): while `act` runs, the server relays Hermes's `assistant.delta` text and
`tool.started` names on a separate in-process bus (`memo/progress.ts`, never `MemoEvents`, which would push a Live Activity update per delta) as SSE `memo.delta`
(`{id, attempt, seq, text}`, coalesced to at most one per 150 ms, the ```iris fence and a trailing fence fragment held back) and `memo.activity` (`{id, attempt, tool}`, immediate).
A client resets its streamed buffer when `attempt` changes (`act` is at-least-once) AND whenever its `/v1/events` stream reconnects, then refetches the detail's `partialReply` (`attempt` is an in-memory per-memo counter that restarts at 1 after a server restart). `GET /memos/:id` carries `partialReply {attempt, seq, text}` while `act` runs and has streamed
visible text, for a client that connects mid-turn (drop deltas of that attempt with `seq` <= it). The final `replyText` stored at `acted` stays the truth and replaces the stream. With today's provider
the text arrives in one burst after the last tool call (docs/research/2026-11-hermes-frames.md), so the tool activity is the live part, not typing.
The iPhone conversation screen shows it (`LiveTurns` in IrisCore folds the events, `ThreadModel` turns them into turns, History multicasts them through `liveEvents()`): a `memo.activity` replaces the pending dashes with a working list, one row per tool started (the last one pulses, finished ones carry a checkmark); once a complete base of reply text exists the pending turn becomes a streaming turn with the id of the final reply (`<memo>.reply`), so the stored reply at `acted` replaces it in place, with no jump. A new `attempt` resets the turn; so does every `ready` (a reconnect), followed by a refetch of `partialReply` as the base. A delta stream that starts mid-turn, or skips a `seq`, stays hidden until that base arrives (the gap rule); a replayed `seq` is dropped. Deltas are display only: never logged, stored or sent to telemetry. With no events the pending turn is exactly the dashes. The tool name is the Iris action name (a loaded skill's own name for `skill_view`, indistinguishable from a tool name on the wire), so the labels are "Using terminal", "Searching the web" and "Using <name>", and never claim "reading a skill". Scrolling sticks to the bottom while the content grows unless the user scrolled up; nothing animates per chunk.
There is no fake typing effect. A memo sent from the screen (`didSend`, `ThreadDetail.appending(sent:)`) shows at once in the same screen, then the fetch replaces it with the server's version.

**Textual** (`gonzalezreal/textual`, MIT, 0.5.0 released 2026-06-15, SwiftPM `https://github.com/gonzalezreal/textual` pinned `exact: "0.5.0"` in `IrisUI`; iOS 18 / macOS 15
minimum, depends on `swiftui-math` and `swift-concurrency-extras`; checked against its README and `Package.swift` at that tag, not from memory). `StructuredText(markdown:)`
renders headings, emphasis, links, lists, block quotes and fenced code with its Prism-based syntax highlighting (the colors are ours, "Reply layout and code themes" below); code blocks scroll sideways
inside their card, text is selectable. Its table label is opaque to a style, so a table cannot become cards through `TableStyle`. `MessageBlock.split` therefore cuts the reply
into blocks first, with the server's fence rules (CommonMark: same character, at least as long, nothing after the closing fence; an unclosed fence runs to the end): markdown goes to
Textual, a GitHub pipe table to `MarkdownTableView` (a grid on the card surface that scrolls sideways when it is wider than the reply, columns aligned by the delimiter row's `:--` / `:-:` / `--:`, a cell wrapping at 240 pt), and
the nth top-level ```` ```mermaid ```` fence to `MermaidImageView` with the same index as `ReplyBlock.index`. A fence the server did not render (no block with that index) stays code.
The diagram is the PNG of the current appearance (`png.light` / `png.dark`, drawn at 2x), fetched through the I1 authenticated media path (`MemoMediaSource.asset`, `MediaDownloader`,
file kept for good since an asset id is never reused) into `ReplyImageStore`, which loads each file once and keeps the decoded image; the card holds the diagram's aspect ratio while it
loads and offers a retry when it failed. A tap opens `ZoomableImageView` full screen: pinch (1x to 6x), drag when zoomed, double-tap between fit and 2.5x, share the image.

**Prose renderer: math, copy, streaming** (`prose-renderer`, numbers and the choice in `docs/research/2026-11-10-prose-renderer.md`). Textual stays; the two candidates that were measured cannot host our own table and diagram views (MarkdownView) or are an order of magnitude slower and miss `$..$` (SwiftStreamingMarkdown). `MathSpans.prepare` finds math by pandoc's rules (so "$5 and $10" stays text), protects the LaTeX from Foundation's markdown parser and switches Textual's `.math` on for a text block that holds a span (in such a block a dollar sign outside a span is shown as U+FE69, because Textual's regex would pair it; a price copied from that block carries the small dollar sign). Every code block header carries a copy button (`CodeBlockProxy.copyToPasteboard`, a checkmark for 1.5 s). `MessageContentView(markdown:isStreaming:)` takes a growing string: while `isStreaming` the text is published through `StreamBuffer` (80 ms, or a new line after 16 ms), `StreamingReplyModel` keeps the finished blocks and splits only what follows them, the text run is cut into chunks at safe paragraph and heading boundaries (one `StructuredText` each, the em gap Textual would have put between them is restored, so the height equals the unchunked layout within 1 pt), and `StreamingTail.stabilize` renders the unfinished last chunk with its emphasis closed, a half link as its label, an open math span, a fence opener or a table header cut. A final update (`isStreaming == false`) is `MessageBlock.split(markdown)`: one `StructuredText` per text run again, so text selection runs across paragraphs. Selection does not cross chunks while a reply streams.

The bar's model is IrisCore's `ReplyBarModel` (the draft, the voice take, `Notice`s the app turns into toasts). Reply by text is the bar's own field: `ThreadModel.sendDraft`
sends it through the composer's path (`ComposerModel(.reply(toThread:))` → the outbox), and a text that could not go out comes back into the field. The server creates a thread at the
first memo's `act` and refuses a continuation of an unknown one, so a reply typed while the first memo is still before `act` is **held** on the device (a user turn and a pending
"Sends after the first answer" turn) and sent by the load that brings the `threadId`; if the first memo ends without one, the text returns to the field with a toast. A held reply
lives in memory only. Voice needs a thread id when the take starts (the outbox creates the memo bound to it), so hold-to-talk and the locked recording are disabled until the
conversation has one. Reply by voice is `VoiceReplyCapture` (IrisCore), the thread's capture port: `begin(VoiceReplyRequest(threadId, mode))` on touch-down of the hold-to-talk pill, `end(cancelled:)` on release (slide up 70 pt to cancel;
a hold under 0.8 s is a cancel with a hint). Production and `-IrisFakeCapture` both use `OutboxVoiceReplyCapture`: the take runs through `CaptureSession`, the
outbox creates the memo (bound to `threadId`), uploads and completes it, and `end` answers `sent(memo)` (the thread shows the pending turn at once), `queued` (a toast: it
joins the thread once it is sent) or `discarded`. `UnavailableVoiceReplyCapture` (the pill is disabled) remains for a build whose recorder could not be created.
A typed reply goes through the same outbox (`ComposerModel` → `OutboxService.submitText`). VoiceOver gets a tap to start and a tap to send instead of a hold; the hint says so.

**Reply bar, one row** (Wave 16 I4, the owner's verdict `docs/design/feedback-reply-flow.md`; the keyboard button became an inline field in issue 680): a text field (1 to 5 lines; once it holds text a send button takes the place of the two voice controls) · hold to talk (the mic, no text while idle) · locked recording
(`mic.fill` with a `lock.fill` badge, composed because no single SF Symbol says "recording, locked"; every name checked against the 27.1 SDK). The locked recording is a tap-to-start
take through the same `VoiceReplyCapture` port and the same `beginVoice` / `endVoice`: nothing new in the capture path. While it runs the bar shows a cross (discard, `end(cancelled: true)`), the
timer, and the send button (`end(cancelled: false)`); a take under 0.8 s is discarded with a "too short" hint. During a hold the side buttons give way to the timer and the release hint. Accessibility
labels: Send, Reply by voice (hint while idle: double-tap to start recording, double-tap again to send; while recording: double-tap to send; the VoiceOver action toggles, so the hint never promises a hold), Record continuously (hint: tap to start, tap send when done), Discard recording, Stop and send. A lock request (`VoiceTakeLock`) only becomes a locked take once the app reports the take running, and any other way of beginning one drops it, so a locked take that fails to start never locks the next one. Every string of the app target is localized (see "Localization").

**Reply layout and code themes** (Wave 16 I4). A thread is exchanges: a question turn and its answer, an `ExchangeDivider` hairline before every question after the first. The question is a
card in the accent tint, the answer an open document under the Iris header; inside it headings step down (title 1.35x, 1.2x with a hairline under levels 1 and 2), a quote has an accent rule on a
quiet panel, tables are a grid that scrolls sideways when too wide, a fence is a card with the language on a header line. The code colors are the **JetBrains Light / JetBrains Dark** syntax of the Zed "JetBrains
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

The optional `summarize` step stays (Wave 21 S1b, owner 2026-11-04): the paragraph below is current, except that a memo without a summary falls back to Hermes's headline before the transcript on alerts.

- **A memo without a summary** (`summary == null`, `notified`, a failed `summarize` step; S1) reads as done. The History row and the detail header fall back to the transcript on
  one line, cut at 60 characters with an ellipsis (the server's own clip for alerts, `Memo.clipped`); the detail has no summary paragraph. In the waterfall the failed step is
  **failed-but-optional** (`StepWaterfallRow.optionalNote`): a warning triangle and amber error box instead of the red cross, "Optional · the memo is done without it", the attempts,
  and **[Retry from Summarize]** (and the retry icon in the action bar), which sends `POST /retry {from: "summarize"}`; the server re-runs summarize and notify, the SSE refresh
  brings the summary back. Only `summarize` is optional; a failed step of a `failed` memo is still the memo's failure. Fixture: `memos.detail.response.summarize-failed.json`
  (decode test in `IrisCore`); the fake API takes that retry on a `notified` memo (back to `acted`), and `SampleData` has one such memo.
- **Money** is `StepText.dollars`: US dollars as the user's locale writes them, no fixed `$`. From a cent up two decimals ("$0.04", "0,04 $"); below a cent four ("$0.0002"), so a real
  cost never reads "$0.00" (Wave 17 I5, `feedback-device-1.md` §5); below a hundredth of a cent "<$0.0001"; zero is "$0". The step chip, the waterfall total and the Stats tiles and
  their per-memo caption all use it.
- **Waterfall** (Wave 17 I5, §4; Details since Wave 22 U1): collapsed by default to one line, "Details" with the total "duration · cost" (`StepWaterfall`, the summary row is a button with an expanded/collapsed VoiceOver value);
  a tap opens the step rows and the ids (the `footer`) under it. A memo in `failed` opens it on its own (the retry sits on the failed row; an explicit tap still wins). Bars are drawn contiguous:
  `WaterfallBuilder` runs each bar from its step's start to the next step's start (the wait between two steps belongs to the earlier bar), the last bar ends with its step, steps are
  ordered by start, and a bar never reaches past its track (a very short step keeps a two-point sliver). The chip keeps the step's true duration.
- **Copy as plain text** (Wave 17 I5, §1): the transcript and the reply each have a Copy button next to the section label; it puts one plain string on the pasteboard (`MemoDetailModel.copy`,
  the `Pasteboard` port), confirms "Copied" for 1.5 s. The transcript is trimmed; the reply (Hermes's markdown) goes through `PlainMarkdown`: emphasis, code marks, heading marks and fences are
  dropped, list items keep their bullet or number, a link keeps its address in brackets (`text (https://…)`), table cells are tab-separated, blocks are separated by a blank line.
  The selectable styled text stays for partial selections; the button is the plain-text path.
- **History without a connection** shows "Not connected" with an Open Settings button (Settings → Connection) instead of a blank list; it follows the form's saves
  (`CompositionRoot.isConfigured` reads `connectionRevision`).
- **The hidden set survives a relaunch.** A memo this device discarded (a cancelled take, a discarded queue row) is hidden from History until the server `DELETE` settles. The ids live in
  a `HiddenMemoStore` (`UserDefaults`, `iris.history.hiddenMemoIDs`; in memory on fakes, so a UI test starts clean) and are cleared by `CreatedMemoLog.settle`, which the uploader calls when
  the delete is over (200, 404 or 409) and `discardQueued` calls when the user stops trying a stalled one. After a 409 (the memo left `receiving` before the delete landed) the memo is a real
  one and shows again with the next refresh. `CreatedMemoLog` hands hide and unhide to History through one ordered stream, and at launch `reconcileHidden` forgets every hidden id that has no delete queued in the outbox (a discarded take
  whose create never landed has none to settle). `HistoryModel.hide` and `unhide` are order-insensitive (a settle that arrives before the hide leaves nothing hidden). `HistoryModel.insert` ignores a memo this session hid and unhid (the create hand-off runs on a task of its own, so it can arrive after the discard's delete settled; the server's list decides). Eviction (`MediaDownloader.evict(memoID:)`) returns at once and scans the cache on the downloader's actor, off the main actor, and cancels the memo's downloads still on the wire: a download lands only through that actor, so one that finishes after an eviction finds its flight gone and discards its file. Known follow-up: eviction happens when the delete returns, so an Undo re-downloads the memo's media.
- **Detail toasts** follow the thread view's rule: a toast has an id, its timer is a task owned by the model, and a newer toast (or a dismiss) cancels the older timer, so a stale timer
  never hides a newer toast with the same words.
- **The fake API answers a typed memo**: `FakePipelineUploader.create` starts the fake pipeline for a text item (routed, then `notified` with a canned answer), so the text reply
  flow runs to its answer on fakes (`ReplyFlowReviewUITests` shows it).

### Two modes and the kind chip (Wave 21 A1; spoken replies, mic rules and Play from Waves 16-18)

Iris no longer routes (§3 "Hermes decides"); the app has two modes and shows what Hermes decided.

- **Two modes, three buttons.** `MemoMode` is `hermes` (the default) and `transcribe`; any other wire value (old memos: `auto`, `chat`, `journal`, `tab`) reads as `hermes`. The record control is the
  tab bar's bottom accessory and shows `RecordRow`: a large Hermes button (starts a Hermes take), a smaller Transcribe button (a take that only becomes a transcript) and a smaller Text button (opens the composer).
  No long press, no menu, no mode sheet: the owner asked for no hidden gestures. The Hermes glyph is `sparkles`: the SF Symbols have no robot glyph. In the `inline` placement (minimized tab bar) the two small buttons drop their titles.
  The composer has two send targets instead of mode chips: "Send to Hermes" (primary) and "Transcribe"; a reply bound to a thread offers Hermes only (the server answers 400 for `threadId` with Transcribe).
  The Lock Screen Record control and `StartMemoIntent` start a Hermes take; a second control, "Transcribe" (`OpenTranscribeRecorderIntent`, the same unlock-then-open flow), starts a Transcribe take.
- **The kind chip.** A memo's chip (`KindChip`, neutral; `KindPalette` colours answer, task, note, github issue and chat) shows `kindLabel`: the localized name of a known kind (`KindPalette.localizedName`: Answer/Antwort, Task/Aufgabe, Note/Notiz, GitHub issue/GitHub-Issue, Chat), any other `kind` capitalised like the server's alert,
  else an old memo's route name (Journal, Hermes, Chat, Tab), "Transcript" for mode `transcribe`, "Hermes" while a Hermes memo has neither yet. An unknown kind is free-form data: `Text(verbatim:)`; the known kinds and the fixed labels have a `de` entry.
  An old memo that was parked at `needs_route` and dismissed reads "Not delivered" and offers no routing; a parked memo that was not dismissed is `failed(act)` on the server since migration 14 and retries from Act.
- **Actions.** The detail shows `actions` (the tools Hermes ran) as one quiet line inside Details, "Hermes used: capture, terminal"; omitted when empty.
- **Filters.** There is no chip row above the list. The filter sheet (the filter button in the bottom search row; its badge counts every active filter) has three groups: View (Favorites, Threads (`thread=true`, conversations of at least two memos), Archived; one at a time), Kind (every kind present in the loaded pages, `?kind=`, a selected kind stays) and State. Reset clears all three and keeps the search. There is no Needs-route filter, no pinned section and no Route swipe.
- **Stats** series are per kind: the top four by count get a palette slot, the rest are "Other", a memo without a kind is "Transcript".
- **Play.** `SpeechPlayer` is the app's one spoken-reply player (one `MemoPlayer`, remembering whose reply it holds): the detail's Play, `PlayReplyIntent` and spoken replies go through it,
  so replies never overlap; the recording of a detail and the speech pause each other (`MemoPlayback`; `SpeechPlayer.pauseRecording` covers a reply the user starts elsewhere, `PlayReplyIntent`, and a pause cancels a reply still downloading). It plays `GET /v1/memos/:id/speech` (the server's speech variant) downloaded with the
  device token by `MediaDownloader`. `PlayReplyIntent` is an `AudioPlaybackIntent` (runs in the app process; `PlaybackIntents.handler` is the composition root, which fetches the memo and plays);
  it is compiled into the widget too. The done Live Activity card and the expanded island have a Play button (`LiveActivityPanel`'s `doneAction` slot, `Button(intent:)`). The card also has a Reply `Link` (`iris://memo/<id>?focus=keyboard`) and a `widgetURL` (the conversation); the `MEMO_DONE` notification has Reply, Reply by voice and Play actions (see Notifications). Compile-checked only: whether a suspended app may start playback from the Live Activity is spike S3, fallback is opening the app.
- **Spoken replies.** Settings → Playback toggle, persisted in `UserDefaults` (`SpokenRepliesStore`, off by default). When on and the scene is active, `memo.done` (`HistoryModel.onMemoDone`) makes
  `SpokenReplies` fetch the memo and speak it if it is `notified`, has a reply, is not deleted or archived, and **this device created it** (`CreatedMemoLog`): the Mac's memos do not talk on the phone.
  Once per memo per launch. A reply that finishes in the background is a notification; Play speaks it on demand.
  **A spoken reply defers (owner decision B, 2026-10-30).** It never interrupts and never pauses anything: while a reply plays or loads (the detail's Play, `PlayReplyIntent`, another spoken reply), the open detail's
  recording plays (`SpeechPlayer.isBusy`), or a take is open (`TakeModel.isCapturing`: starting, recording, paused or stopping, a thread's hold-to-talk included), the memo is not spoken. It is marked as spoken-or-skipped,
  so there is no queue and no auto-play later when the player goes quiet or the take ends; the reply stays available as the memo's notification and [Play]. Checked at `memo.done`, after the memo is fetched, and again
  when the speech has downloaded: a take that opened meanwhile cancels the start even if it is over again by then (`TakeModel.takesStarted`, compared against its value when `memo.done` arrived), and the memo is skipped. One rule (`SpokenReplies.skipWhileBusy`) serves all three checks; a failed download is not a skip. When nothing plays or records nothing changes.
  **A take start pauses playback (Wave 18 I1, mother default 2026-10-30, owner may overrule; his I3 answer was "rather B, pause playing").** Recording takes priority and the reply is never recorded into the take. One synchronous flag carries it:
  `TakeController.captureActive`. A start sets it before it awaits anything (`start`, and a thread's hold-to-talk through `OutboxVoiceReplyCapture.claim`, first line of `begin`; the same `claimCapture()` also calls `SpeechPlayer.pauseForTake()`), and it is
  cleared only once the session has ended: after `stop()` / `cancel()` return (a stop that hangs in the recorder keeps it set until it returns; the session's own 10 s bound still applies), or when a start fails and no take is running, or (Wave 19 I1) when a take **failed on its own** and its recorder has stopped: the session publishes `TakeState.recorderReleased` once the failed take's recorder stop has returned, and `TakeController.sessionUpdated` (fed by `TakeModel`'s follow of the session) releases the claim (the failed take's audio session is not deactivated by the failure, only by its Stop or Discard; the recorder is stopped, so the microphone is free, but the effect of the still-active session on playback is device-unverified), so spoken replies resume without a Stop or Discard the user may never press (the take stays `failed` and waits for him; a stop that never returns keeps the claim). No timeout,
  no mirror of the model's state. `pauseForTake()` pauses the spoken reply and the open detail's recording and drops a speech that is still downloading (so it cannot attach afterwards). Paused, not released: nothing resumes by itself when the
  take ends, the user presses Play again. Every playback start reads the flag (`SpeechPlayer.captureActive`, bound weakly by the composition root) at the moment it starts, with no `await` between the check and the start: `play` (the detail's Play,
  `PlayReplyIntent`, spoken replies) checks on entry and again after the speech has downloaded, together with `shouldPlay` (setting, foreground); resuming a paused reply and the recording's play button check too; pausing never does. Together with the
  rule above: a take and a reply never overlap, whichever came first. Unit: `ReplyPausesForTakeTests`.
- **Per-route mic rules (R-CAP-4).** The capture engine already keeps `[routeFingerprint: preferredPortUID]` and applies the rule when a take starts (`CaptureSession`); Wave 16 adds the UI:
  Settings → Microphone shows the active route (`RouteSnapshot.outputNames`, new, for display only; the fingerprint is still the sorted output UIDs) and its inputs, Automatic removes the rule.
  Only the active route is editable: other routes get their rule when they are the active one (the rules store holds fingerprints, not names). Device-verified: nothing (no phone paired); simulator: the fake route manager.
- **Tests.** Unit: `SpeechPlayerTests`, `SpokenRepliesTests`, `MicRulesModelTests`, `MemoPlaybackTests`, `ComposerModelTests` (the two sends), `MemoPresentationTests` (the kind label rules), `HistoryFiltersTests`. Snapshots (light + dark): the kind chip, the mic rule list, the done card and island with Play.
  UI (`ModesUITests`, `-IrisFakeCapture`): the record row's three buttons, Play toggles, a mic rule picks the input of the next take, the spoken-replies toggle. The fake API's samples carry kinds and actions, an old memo with a route and no kind, and a transcript memo.

### Localization (Wave 19 R3)

English is the source language, German (`de`) the only translation (the owner's phone is German). Research and the verified facts:
`docs/research/2026-10-31-string-catalogs.md`.

**Catalogs, one per target that ships text** (the extensions are separate bundles; a catalog is a resource of the target that compiles it):

| Target | Catalog (`Resources/`) | Holds |
|-|-|-|
| `Iris` | `Iris/Resources/Localizable.xcstrings`, `InfoPlist.xcstrings` | every string of the iPhone app, the intents, the microphone prompt |
| `IrisWidgets` | `IrisWidgets/Resources/Localizable.xcstrings` | the Live Activity, the Record control, and the intent files it compiles from `Iris/Intents` (their keys live in both catalogs) |
| `IrisMac` | `IrisMac/Resources/Localizable.xcstrings`, `InfoPlist.xcstrings` | the Mac app and the shared `Iris/*.swift` files it compiles in |
| `IrisUI` (package) | `Sources/IrisUI/Resources/Localizable.xcstrings` | the shared components; reached with `bundle: #bundle` |

`IrisNotifications` has no literal of its own (it renders `IrisUI`). `project.yml` sets `SWIFT_EMIT_LOC_STRINGS` and
`LOCALIZATION_PREFERS_STRING_CATALOGS` for every target (a generated project gets neither from Xcode); `de` reaches `knownRegions` from the catalogs,
so the built bundles carry `de.lproj` (the unit test `LocalizationTests` proves it per bundle).

**How a string is written.** The English text is the key; `comment:` says where it appears.

| Where | Form |
|-|-|
| A SwiftUI view with a literal | `Text("Key", comment:)`, `Button("Key")`, `Label("Key", systemImage:)`, `.navigationTitle("Key")` (a `LocalizedStringKey`) |
| A `String` (a model, a title parameter, a `Button(String, ...)`) | `String(localized: "Key", comment: "...")` |
| App Intents, widget and control names | a `LocalizedStringResource` literal: `static let title: LocalizedStringResource = "Key"`, `IntentDescription("Key")`, `.displayName("Key")`, `@Parameter(title: "Key")` |
| Inside a Swift package | `bundle: #bundle` on every one of them (`Text("Key", bundle: #bundle, comment:)`, `String(localized: "Key", bundle: #bundle)`): a bare `Text("Key")` looks in the app's bundle and shows English. `Button("Key")` and `Label("Key", ...)` have no `bundle:`; write `Button { } label: { Text("Key", bundle: #bundle) }` |
| Data | `Text(verbatim:)`, or a plain `String` that is not a title: never in a catalog |

Rules that cost a bug once: `Text(flag ? "A" : "B")` types its literals as `String` and is never localized (give the call a `comment:` or wrap each branch in `String(localized:)`);
a `%` in a key is `%%`; a number or string interpolation becomes `%lld` / `%@` (by the interpolated type), and a translation that reorders them uses `%1$@`; a count whose noun
changes gets plural variations in `en` and `de` (the check reads every leaf).
Not localized, by design: memo transcripts, replies, summaries and headlines; route and tab names the server returns; error codes and messages the server sends;
the spoken route prefixes (`hermes`, `journal`, `tagebuch`, `tab <name>`: they are what the server matches); ids, durations and numbers (formatters, locale-aware);
logs, telemetry and accessibility identifiers.

**The check** (`scripts/check-strings.ts`, `make check-strings`, in `make check` and `check-apple`, so CI on Linux runs it too) fails on: a catalog key with no translated `de`;
a `de` value (every leaf of a plural or device variation) whose format specifiers differ from the key's, compared per argument index with type and length modifier (`%1$@ %2$lld` is not
`%lld %@`; a plural `one` may drop an argument, no leaf may add one or change a type), and a German plural without `one` and `other`, an empty variation branch (nested ones too), one argument index given two types (`%1$@ %1$lld`), and a positional key (`%1$lld of %2$lld`: the compiler extracts `%lld of %lld`, so a positional key is never looked up); a stale key (no literal of that target names it;
`extractionState: manual` is exempt, for keys looked up dynamically); a user-facing literal whose key is not in the catalog of every target that compiles the file, or whose interpolated
type contradicts the key's (`%lld` vs `%@`); a bare literal for a `String` parameter named `title`, `message`, `detail`, ...; a ternary of literals or a concatenation (`Text("a" + "b")`) that
types as `String`; in a package any literal that is not `Text(_, bundle: #bundle)` / `String(localized:, bundle: #bundle)` / `LocalizedStringResource(_, bundle: #bundle)` (`#bundle`, `.module` or `Bundle.module` as the call's own argument; a bare `LocalizedStringResource` literal, `bundle: .main` or a nested call's bundle fail; `// l10n:bundle-ok <why>` accepts a `bundle:` parameter a caller fills with `#bundle`) (a bare `Button("x")` or `.accessibilityLabel("x")` there looks in
the app's bundle); a `NS*UsageDescription` without an `InfoPlist.xcstrings` key. Limits: a lexer, not a type checker. An interpolation's type is known only for a number or string literal,
`.count`, `Int(..)` / `Double(..)` / `String(..)`, `.formatted(..)` a name the same file declares once with a plain type and a `let x = <those>` local; any other expression is accepted against a key of any type
(a wrong key then misses at run time and shows English, it does not crash). It sees literals at the call site only (a `String` assembled elsewhere and passed to `Text(variable)` is
invisible), a view initializer it does not know is unchecked (`VIEW_INITS`), fake and sample data files are exempt from the `String` rule. A literal that is really
data is marked `// l10n:ignore <why>` on its line or the line above. Its tests are `scripts/check-strings.test.ts`.

**Glossary** (keep the same word for the same thing; neutral address, no du/Sie: nouns, infinitives and short imperatives like the system apps):

| English | German | Note |
|-|-|-|
| Memo | Memo | |
| History | Verlauf | the tab and its screen |
| Settings | Einstellungen | |
| Stats | Statistik | |
| Recording / Record | Aufnahme / Aufnehmen | `Aufnahme läuft` for the running state |
| Reply (noun / verb) | Antwort / Antworten | |
| Retry | Wiederholen | `Jetzt wiederholen`, `Wiederholen ab <Schritt>` |
| Transcript | Transkript | |
| Route / Destination | Route / Ziel | |
| Steps | Schritte | the pipeline steps |
| Outbox | Warteschlange | |
| Conversation / turn | Unterhaltung / Runde | |
| Done (user flag) / Done (pipeline state) | Erledigt / Fertig | the flag a user sets vs. a finished step, memo or Live Activity |
| Favorite, Archive, Delete, Discard, Cancel, Undo | Favorit, Archivieren, Löschen, Verwerfen, Abbrechen, Rückgängig | |
| Connected / Unreachable | Verbunden / Nicht erreichbar | |
| Token, Keychain | Token, Schlüsselbund | |
| Chat, Hermes, Journal, Tab, herdr | unchanged | product and destination names |

**Verification.** `xcrun simctl launch <udid> com.jkrumm.iris -IrisFakeCapture -AppleLanguages "(de)" -AppleLocale de_DE` runs the app in German (skill `ios-verify`);
the German screens are checked for truncation, and a UI/snapshot test is added only where a German string broke a layout. Device-only: the Control Center and Lock Screen
names of the Record control, the Live Activity text and the Siri/Shortcuts phrases (the widget extension is localized and compile-checked; nothing there renders on the simulator).

### UI tests on the hosted runner

"Failed to terminate com.jkrumm.iris" on `StatsSettingsUITests` / `MemoDetailUITests` / `ReplyFlowReviewUITests`: the one log that was kept (run 40829501216) shows it inside
`XCUIApplication.launch()`. That call first ends the instance the previous test left running (`Terminate com.jkrumm.iris:<pid>`), the loaded VM then answers nothing for ~55 s, and
the failure is charged to the next test. The app is idle at that moment (no app-side hang found; the earlier flakes have the same shape but their logs were not kept, so that part is
an inference). Instead of guessing at the app, every UI test class now derives from `IrisUITestCase`: the app is started through
`start(_:)` and ended in `tearDown` (so the next launch has nothing to end), a terminate that stalls is retried, and its failure is recorded as an expected failure
(`XCTExpectFailure`, non-strict, matched on the message); the third launch attempt is strict, so an app that really cannot start still fails the test. Sampling the app at teardown on
the runner needs a workflow step and was left out of this change (owned files: `apple/**`).

"Failed to get matching snapshots: Timed out while evaluating UI query" (`ReplyFlowReviewUITests`, then `CaptureUITests` at a bare `row.exists` in run 41017094962) has one cause: reading any attribute of an element (`exists`, `frame`, a `label CONTAINS` predicate over `.any`) snapshots the whole accessibility tree, and a loaded VM does not get an animating History list or a thread with a rendered answer through that in time. A bare query in a polling loop gets many chances to hit it. `IrisUITestCase` now owns the waits: `waitForPresence`, `waitForAbsence`, `staysAbsent` (an element that does not show up during a whole window, for "the deleted row did not come back"), `presence(of:within:)` (true, confirmed absent, or inconclusive: `revealRow` swipes only on a confirmed absence) and `revealRow(containing:in:)` ask again until their deadline when a query times out (`QueryRetry`: `XCTExpectFailure`, non-strict, matched on the message, like the terminate retry) and fail only for an element that is really not there; `scrollIntoClearBand` goes through the same retry, and the pending-turn and answer waits of the reply-flow tests wait on that explicit element state instead of polling two queries every 200 ms. A new test uses these, not a bare `exists` in a loop.

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
  - on a resume recommendation the session is reactivated first (a session an interruption deactivated makes `engine.start()`
    fail; up to four tries), then the engine restarts, and an engine that will not restart is replaced by a fresh one with the tap;
  - `mediaServicesWereResetNotification` (the audio daemon restarted) closes the open segment of a recording take, sets the
    category again and continues in a new segment on a new engine; a take that was paused (by the user, or by an interruption
    that did not recommend resuming) stays paused.
- **`RouteManager`:**
  - lists `availableInputs`, applies `setPreferredInput` after activation, and
    reads back `currentRoute`;
  - per-route rules in device-local settings (`[routeFingerprint: preferredPortUID]`),
    applied at start and on route change;
  - publishes `currentInput` for the UI and the Live Activity.
- **`SegmentRecorder`:**
  - an `AVAudioEngine` input tap → `AVAudioConverter` → `SegmentWriter` (an
    `AVAssetWriter` fragmented m4a, AAC, 16 kHz mono, about 32 kbps; a
    fragment every 0.5 s, so a file whose writer was killed still plays up to
    its last whole fragment and the startup sweep adopts it like any orphan;
    a segment is queued once its writer has finished and the file reads back;
    `docs/research/2026-10-30-avaudiofile-kill.md`; `SegmentCloser` bounds the writer's `finishWriting` (30 s,
    Wave 19 I1): a finish that never returns fails that segment's close in order like a failed finish, publishes nothing, halts
    the later segments of the take and ends it with `.failed`, and the file stays on disk for the next launch's sweep, never
    deleted and never read while its writer may still be changing it. This is a hard failure on purpose: a finish that answers after the limit is not accepted late, since the take already ended with `.failed` and later segments were held back; the file, if it reads back and fits the take, is adopted by the next launch's sweep, else set aside);
  - rotates files every 10 s of frames, on a mic switch, and on an
    interruption;
  - each closed file goes to the `Outbox`; a segment still open when the app dies is a fragmented m4a that plays up to its last whole fragment (all but about a second; Wave 17 D2 lost three whole segments to the unfragmented format), and the startup sweep adopts it as the take's next segment, a killed first segment included (the take's item waits for the sweep, which attaches index 0 or drops the empty take); a file that does not play (killed before the first fragment) is set aside, never deleted. After a segment fails to close (the encoder stopped, the file does not read back) no later segment of the take is queued: a prefix that still plays goes up with its real duration, the take fails, and the later files stay on disk;
  - a level meter is fed from the tap's RMS on a perceptual scale (`InputLevel`, Wave 17 I5): linear in dB between −50 dBFS (0) and −10 dBFS (1), a clipped sample reads 1; normal speech
    (about −30 dBFS) sits at the middle, where the linear amplitude left it near the floor;
  - an engine configuration change (a mic switch, AirPods connecting) closes the segment and replaces the engine with a fresh
    one carrying the tap. The tap's format is the node's current `outputFormat`, installed only when it is non-empty and its
    sample rate equals the hardware's (`inputFormat`); otherwise the bring-up is retried for about 1.5 s, then the take fails
    with its segments kept. The audio engine calls (`installTap`, `start`, `stop`, `removeTap`) run through `IrisObjCGuard`, a
    small Objective-C target that turns the exceptions AVAudioEngine raises into errors. Wave 17 D2.6: switching to AirPods
    mid-take aborted the app (`SIGABRT`, uncaught `NSException` from `installTapOnBus` in the config-change re-install, which
    used the old format after the HFP route change). The converter follows each buffer's format.
    The first engine of a take is brought up the same way (up to four tries), since a start with AirPods connected hit the same
    exception. While a restart is in flight `pause()` and `resume()` only record the wanted state (`EngineRun`), which the
    restart applies to the new engine; a take that ends or begins meanwhile makes the restart's engine stale and it is torn down.
  - **A pause keeps the engine running (Wave 18 I7).** `pause()` closes the segment and the recorder drops the samples; it no longer calls `engine.pause()`, which stops the
    hardware. Device (Wave 18 D1): island Pause passed, island Resume said "engine resume failed" (`cd6f0e19`). The island's buttons are `LiveActivityIntent`s performed with the app in
    the background; once the paused engine had stopped the hardware there was no audio I/O to keep the app alive and the start of an engine from the background is refused
    (`!rec`, 561145187; Apple DTS: "usually happens when trying to start a recording while the app is in the background"). A running engine needs no start, so Resume is a flag. The
    session is activated again first (`CaptureSession.resume`; a no-op on a live session). An engine the system stopped meanwhile (an interruption, a configuration change)
    is replaced by a fresh one with the tap, retried like a restart (`EngineStartup.resume`, up to six tries 250 ms apart), never restarted on its old tap and format; when that
    fails too the take is `failed` and says so. Samples are gated at capture time, not at consumption: the tap stamps each chunk with a pause epoch (`PauseGate`, changed by every pause and resume) and drops it while paused, and the consumer ingests a chunk only while its epoch is current, so audio captured around a pause that the consumer reaches late can never land in a segment after the resume. A resume whose session activation stays failing (retried, 4 tries) fails the take with "audio session could not be restored" instead of reporting recording. **Known cost: the microphone indicator (orange dot) stays on while a take is paused**, and the engine keeps drawing power; nothing is written. The cause is a hypothesis fitted to the evidence (no
    log of the failing call existed); the next device take shows it in `capture.session.error` (`call`, FourCC, `app.state`) next to `take.phase`.
- **`Outbox`** (Wave 15 I3): a persistent queue of **whole items**, in one JSON file (`Application Support/Iris/outbox.json`,
  written atomically, each segment named by **file name only**: the app's data container gets a new path when a build is installed over it (found on the first device, Wave 17 D1b), so an absolute path saved by an earlier run pointed at nothing, the upload failed as "the recording file is gone" and stalled while the audio sat unharmed in the new container. `JSONFileOutboxStore(segmentDirectory:)` puts every segment in the current capture directory on load, which also heals a record written with absolute paths, and a segment that had stalled on such a stale path with its file present is retried once; a file that is really gone stays stalled. A file that cannot be read or decoded (including a newer build's enum case) is an **error, never an empty queue**: it is left on disk untouched and the outbox reports itself closed (below), until Settings **"Reset outbox"** (Wave 16 I1) renames it aside: `outbox.quarantined-<UTC timestamp>.json`, kept next to it, never deleted, its segment files untouched, and a fresh empty outbox opens. Diagnostics lists the set-aside files with a `ShareLink`. A second tap while the reset runs joins it (`CaptureStack` keeps the one reset task) and gets its outcome; it is not reported as a failure. The reset claims the move in the same actor turn it starts (the stack already knows the file is unreadable from the refresh that offered the button), so no `open()` can read the file between the tap and the rename. An item whose write fails (a full disk) is taken back out and refused, so nothing is ever "queued" that a kill would lose. Three kinds of work, all
  idempotent on the server, so a retry after a lost answer is harmless:
  - A segment `PUT` for a memo that has left `receiving` is 409 `bad_state`, and the server answers it before it compares bytes. `APIOutboxUploader` then asks `GET /memos/:id` what the server holds: with `segmentCount` above this index the segment is **delivered** (the memo was completed with it: a lost answer, or the audio sent by hand), `complete` returns the memo it has and the queue clears; with fewer, the local file is the only copy, so it is **set aside** (the capture directory's `quarantine/`, which Settings counts and sizes) and the entry clears, never deleted. No place to keep it, or no answer to the lookup, is a stall or a retry, not a decision. A 409 `conflict` (other bytes) stays a refusal.
  - `complete` answered 422 `missing_segments` (the server holds fewer segments than the phone sent: a restored backup, a write refused in flight) is **not a refusal**: the files stay until `complete` succeeds, so the listed segments go back to pending and `complete` follows them on a backoff (`MissingSegmentsError`, `OutboxStateMachine.completeMissingSegments`), counted like any failure so a server that keeps losing them ends in a stall; an index the phone does not hold is the stall it was.
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
    the hide and the delete's settle reach History in either order (`TakeController.cancel` hides after the session has queued the `DELETE`, which can be acknowledged first): a settle that finds the id not hidden is remembered, and the hide that follows removes the row without keeping the id hidden, so a deleted memo is never left hidden for good (Wave 19 I1).
  - **bound to its server (Wave 19 I1).** `OutboxItem.serverKey` (a digest of the server URL, `ConnectionCredentials.serverKey`, the same value as `MemoAttributes.serverKey`) is stamped by `Outbox.enqueueItem` from the `serverKey` provider the stack was built with (`CaptureStack.Parts.serverKey`, the live connection), once, when the item is queued, and saved with it; a `DELETE` copies it (`OutboxDeletion.serverKey`). The state machine hands out work (the create, the item's segments and `complete`, the delete) only while the configured server is the bound one (`dispatch(serverKey:)`): after a switch to another server the work stays queued and visible, with its attempts and backoff untouched, and goes out when the first server is configured again (`OutboxService.resume()` runs on a connection change). Work bound to no server (a record from before, a stack with no provider) goes to whichever is configured. The check at dispatch cannot see a switch between the dispatch and the request, so every transfer runs with `OutboxTransfer.serverKey` set (a task-local) and `ReconfigurableAPIClient` compares it with the connection it holds at the moment it picks its target, in the step the swap takes: another server throws `WrongServerError`, which the outbox treats like a cancellation (the transfer goes back to pending, no attempt, no backoff, nothing sent). The memo a create returns is recorded with its server (`CreatedMemoLog.record(_:serverKey:)`, `setServerHandler`); `HistoryModel` reads its server from the same client (`serverKey`) and merges nothing from another: a first page, a next page or an event refresh whose server changed meanwhile is dropped, the rows of the server just left are cleared when the new one's load starts, and a created memo of another server (`insert(_:origin:)`, its hand-off hops to the main actor and can arrive after a switch) is not inserted. The Mac binds only once its composition passes the same two providers (`CaptureStack.Parts.serverKey`, `HistoryModel`'s `serverKey`); until then its items are unbound.
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
  know is **adopted** when it belongs to a take the queue holds, fills one of its indices (below its count, or the next one after a take recovered from a crash, or after a finished take whose `complete` was never handed out, which then grows: a stop that gave up on the recorder finished the memo without its tail, and the app died before the tail's file was saved; `OutboxMemo.completeMayHaveLanded` (always written; a queue file from before the flag reads "may have landed" unless the rest of the queue proves otherwise: `complete` follows the create and every segment, so a memo whose create or a segment is not uploaded was never completed; a `pending` completion with no attempts is also what "Retry now" leaves behind) is set and saved with the dispatch of `complete`, and from then on the server may hold the memo closed at the old count, so a tail is set aside instead: a segment `PUT` would be 409 `bad_state` and `complete` with a larger count 409 `conflict`) and
  opens as audio with frames in it (a truncated AAC file does not); otherwise it is **moved** into `capture/quarantine/`. A file that a set-aside queue file names stays where it is, and when a set-aside queue file cannot be read, every candidate stays where it is (the read failure is logged).
  **Nothing is deleted** (the files of a memo the server completed, left by a crash between the save and the removal, are quarantined too).
  **A file the sweep cannot move** (a full disk, a read-only volume) stays in the capture directory and is tried again at the next launch; `SweepReport.stuck` / `Outbox.strayFiles()` (described by the `SegmentFileStore`) list it and Settings counts it with the set-aside files, marked "not moved" in the shared list. **Set-aside files are surfaced, not bounded by deletion.** `capture/quarantine/` and the `outbox.quarantined-*.json` files grow only when something went wrong, and the app never removes them on its own: Settings
  shows "Kept on this device" (count and size, `SetAsideSummary`) with a share/copy of the list (names, sizes, dates; no audio), and past 50 files or 200 MB a note says so. A delete action waits for the owner's word.
  Everything runs on a default `URLSession` (`URLSessionAPIClient`); the background `URLSession` and the `result?wait=600`
  long-poll as a background download are not built (device-only, below). The app side is `OutboxService` (submit text, await the
  first attempt for six seconds and answer `sent(memo)` or `queued`, retry, discard, the queue for Settings) over a lazy
  `CaptureStack` (the outbox and the `CaptureSession`), with `APIOutboxUploader` as the network adapter and
  `CreatedMemoLog` as the hand-off of the memo the server returned.
- **`CaptureSession`:** one take behind one handle. `start(TakeRequest)` mints the memo id, configures and activates the session,
  applies the route rule, starts the recorder and registers the take with the outbox; closed segments go to the outbox while the
  take runs; `stop()` flushes the last segment and finishes the memo (a take that never closed a segment is dropped); `cancel()`
  discards the memo and deletes its files (the outbox retires the queued segments' files; the capture directory's files of the memo
  that never became an entry, a segment whose close failed and those held back behind it, go through `SegmentFileStore.discardFiles(of:)`
  after the recorder has stopped. Only a cancel deletes a take's audio); an interruption pauses the recorder at a segment boundary and resumes it when the system
  recommends; `switchInput` rolls the segment, and so does a route rule that applies mid-take (behind the same gate, only while
  recording or paused), so one file never holds two inputs. `updates()` is the state stream the UI and the Live Activity follow.
  A recorder failure (`.failed`: a segment write error, an engine that will not resume or restart) is a take failure: the session
  stops the recorder (which closes the open segment), moves the take to phase `failed` (`TakeState.failure` says why; `recorderReleased` turns true when the recorder's stop has returned) and
  finishes the memo with the segments that closed, at once: a locked phone or a killed app must not hold captured audio
  back for a stop that never comes. The user's `stop()` then acknowledges the failure and `cancel()` drops what the outbox
  still holds (a memo the server already completed stays). An interruption that ends without a resume recommendation leaves
  the take visibly `paused` with everything before it closed and queued. a failed take whose recorder cannot be stopped (the stop throws or hangs) waits as a silent recorder does: the tail segment and `stopped` it put on the stream are delivered first and finish the memo with the whole take, else the grace period does with the segments that closed, without the user having to look at the phone (a `stop()` in between leaves the finish to the pump, so a queued tail is never overtaken, also when nothing has closed yet: the memo stays open and is dropped by the pump or the grace period only if no tail came; a `stop()` that is still reading the take keeps its count and failure until it returns) (a segment it closes after that is late and stays on disk for the sweep); `stop()` on a failed take returns the memo with the segments that really closed (`TakeResult.failure` set) or, with none, throws
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
  so a `.stopped` that lands between the two finishes the memo once and is not mistaken for a late one. `cancel()` has the same bounds, and drops the tail. A `stopped` that did arrive while `stop()` hung counts as reported (the memo is finished once, no failure). While a given-up `recorder.stop()` has not returned the recorder may still hold the microphone, so `start` refuses (`engineFailure("the recorder is still stopping")`) until it does. The audio session is not deactivated under any recorder stop that has not returned (a failed take's included, `CaptureSession.unreturnedStops`; a cancel during `failTake` too): the take ends with the session active and the last stop's return deactivates it behind the take gate (so a take that starts meanwhile is not cut off), and `start` refuses until every stop has returned. `TakeController.start` is single-flight: a second start while one is in flight (the Control and the record button together, a double tap)
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

- **The intent:** `StartMemoIntent: AudioRecordingIntent, LiveActivityIntent` starts the engine and
  `Activity<MemoAttributes>.request(...)` in `perform()`. Apple requires the Live Activity, or the recording stops.
  **`LiveActivityIntent` is what makes the Control work** (S1 FAIL on the device, Wave 17): a `ControlWidgetButton`'s intent is
  performed in the widget extension by default; only `LiveActivityIntent` (also `AudioPlaybackIntent`, `openAppWhenRun`) moves it to the app's
  process, which the system launches in the background, and a Live Activity may only be started from the background through a
  `LiveActivityIntent`. `AudioRecordingIntent` alone does neither: `perform()` ran in `IrisWidgets`, found no handler (it is
  registered by the app) and threw `appNotReady`, which a control swallows (no crash, no Iris process, only IrisWidgets).
  `openAppWhenRun` is deprecated in iOS 26 and errors inside an extension; `supportedModes` is only a suggestion a control overrides.
  Built (Wave 15 I3): the intent file lives in `Iris/Intents/` and is compiled into the app and the widget extension (the
  `ControlWidget` names the type, the app performs it); `perform()` calls the `CaptureIntentHandler` the composition root
  registered at launch (`startMemo()`: server saved, microphone permission, `CaptureSession.start` in `auto` mode, then the
  Live Activity through `TakeLiveActivityCoordinator`). It compiles and runs in the unit tests on the simulator
  (`StartMemoIntentTests`: the fake stack, a recording `TakeLiveActivity`); **pressing the Control and a real
  `Activity.request` from the background are device-only.** Device result (Wave 17 D2, iPhone 15, iOS 26.6.1, `docs/spikes/S1-lock-screen-start.md`): the Record control, from the Lock
  Screen and from Control Center, starts nothing (no take, the app is not launched, only the widget extension runs); Siri has no phrase (no `AppShortcutsProvider`); a take started in the app
  requests its Live Activity and runs fine. The cause (Wave 17 I8) is the intent running in the extension process without the app's handler; it is now a `LiveActivityIntent` (above), so
  S1's central question stays open until the owner presses the Control on the phone; the `openAppWhenRun` fallback below is not needed for it and is deprecated in iOS 26.
- **The Record control is an `OpenIntent` (Wave 18 I7).** Device re-test (build `459a517`, iPhone 15, iOS 26.6.1): Control Center started a take and opened the
  app (memo `a66fc402`), the Lock Screen press did nothing, also after unlocking. Apple (WidgetKit, "Creating controls to perform actions across the system"; App
  Intents, "Configuring the runtime behavior of your app intents"): the system runs a control's intent in the widget extension, in the background; opening the
  app takes an `OpenIntent` whose file is in the app and the extension (`ControlWidgetButton(action:label:)` has an `OpenIntent` overload for it); a Lock Screen button is inactive until the
  device is unlocked, and `authenticationPolicy = .requiresAuthentication` makes the system ask for that before the intent runs. So the control runs
  `OpenRecorderIntent: OpenIntent` (`target: RecorderDestination`, one case; `authenticationPolicy = .requiresAuthentication`): the press asks for the unlock,
  opens the app, and `perform()` (in the app, in the foreground) calls `startMemo()`, where a session activation and `Activity.request` are allowed. A start that fails
  is `TakeModel.failure` (the alert of `RootView`) and is thrown back to the system, so a press never ends in silence; a cold launch waits up to 3 s for the composition
  root's handler (`CaptureIntents.readyHandler`). `StartMemoIntent` (`AudioRecordingIntent, LiveActivityIntent`, background start) stays for Siri and the Shortcuts app and is
  not what the control runs. Not documented by Apple and so device-only: the state the person lands in after the unlock prompt, and whether a background
  `AudioRecordingIntent` start may open the microphone from a locked device at all (a forum report shows `setActive` failing with `561015905` (`!pla`) there).
- **Callers:** the `ControlWidget` button runs `OpenRecorderIntent`. Siri ("Record
  with Iris") and the Shortcuts app run `StartMemoIntent`.
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
  - `phase` (recording/paused/uploading/processing/done/failed). `recording`, `paused` and `uploading` are the
    client's own (Wave 15 I3): `TakeLiveActivityCoordinator` sets them locally while the take is on the phone (recording while it
    runs, paused during an interruption, uploading from the stop until the outbox has sent the memo), then `processing`, and the
    server's pushes (`processing`, `done`, `failed`) carry it from there.
    The activity's push token is kept by `ActivityTokenRegistrar` per memo until the activity ends, not until the hand-over: a PUT
    that failed is retried with a growing delay, and a token that rotates later is sent too. One `PUT` per memo is out at a time, so a rotation that arrives while one is in flight is sent after its answer and an older token's slow answer
    can never replace a newer one; the in-flight gate is keyed by memo id, not held on the entry, so a `finish` + `begin` of the same memo during a `PUT` makes the new entry's sender wait and then carry on with the newest token (never two `PUT`s at once).
    The coordinator follows each memo on its own and the activity handle is kept per memo, so a take that starts while the last one is
    still uploading neither cancels nor overwrites it, and a stopped follower writes nothing more.
    A retryable failure (no network, a 5xx) keeps the activity on `uploading`; a stall or a recorder failure ends it as `failed`
    (shown 15 minutes) and a discard ends it at once (`Activity.end`); a sent memo is handed over to the server, not ended. The activity's push token is registered
    (`PUT /memos/:id/activity-token`) once the server has the memo, since it answers 404 before that, and retried on the next update; at
    launch every activity still in a client phase is ended, because nothing moves it on after its process is gone (`endOrphans()` also runs when the connection changes, and spares the takes this process is driving, so changing the server URL mid-take does not end that take's activity).
    **Stale activities** (`StaleActivityRule`, `StaleActivitySweeper`; Wave 17): without a push token (`pushToken == nil`: a Personal Team build has no
    `aps-environment`) the server's `end` never arrives and a `processing` activity would sit on the Lock Screen and in the island for
    up to 8 h, hiding a running take's controls. So (1) at the hand-over an activity without a token is followed: the sweeper polls
    `GET /memos/:id` (3 s, doubling to 30 s) until the memo `isResultReady` and then ends it on that result (`done` / `failed`, shown 15 minutes like the server's `end`); (2) at launch (`endOrphans()`) every handed-over activity is checked
    the same way and ended at once when its memo is finished (no token), gone (404) or older than 30 minutes (`StaleActivityRule.maxAge`, token or not: the
    server's `end` is 15 minutes after done); one without a token whose memo is still in the pipeline gets a follower as in (1);
    an activity with a token and a young memo is the server's; (3) a starting take
    (`ActivityKitTakeLiveActivity.start`) first ends the finished (`done`, `failed`) activities and those nothing will update
    (`processing` without a token), so the take's activity owns the island; a `processing` activity the server still
    drives stays. A server that cannot be asked keeps a young activity. Unit-tested on a fake catalog and `FakeAPIClient`; the ActivityKit adapter is device-only.
    **Why the card survived Stop and `done` (Wave 18 I7, device row 20; read from the code, the device proof is the `liveactivity.snapshot` records):** every one of the above runs inside the app process, and an app
    whose take was stopped from the island or the Lock Screen is suspended seconds later (the recorder's audio I/O was the only thing keeping it running). The follower's poll froze with it, the server cannot push (no
    APNs), and the launch / foreground sweep only runs when the owner opens the app. So (4) a hand-over made while the app is not active, and the move to the background (`scenePhase == .background`,
    `CompositionRoot.backgrounded()` under a background-task assertion), end every handed-over activity without a push token at once with `ActivityDismissal.soon`
    (`StaleActivitySweeper.endUnreachable`): the activity keeps showing what it showed and the **system** removes it a minute later, with the app asleep. The follower still serves the app while it is on screen (the result card
    for 15 minutes); (5) the hard age limit is `StaleActivityRule.maxAge` = 30 minutes, checked at launch and at every foregrounding. An activity with a push token stays the server's until then.
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

### Live preview (Wave 19 R1, PRD R5)

The take screen shows the transcript as it is spoken, from the on-device `SpeechAnalyzer` / `SpeechTranscriber` (iOS 26). **Display only:** the server's
transcript stays the truth; the preview is never uploaded, stored, logged or put into telemetry, lives as long as the take and goes with it. A preview that cannot
run shows nothing and never blocks or fails a take.

- **Tap (`IrisCapture`, `PreviewTap`):** an additive port. `openPreview()` returns a bounded `AsyncStream<PreviewAudio>` (16 kHz mono Float32, the samples the recorder
  accepts in `ingest`, i.e. after its pause gate; about ten seconds of buffers, oldest dropped). Nothing is copied or buffered while no stream is open; a released stream
  closes the feed on the next yield; `stop()` (which `cancel()` also calls) finishes the stream. It never touches `SegmentRotator`, the writer or the outbox.
  `AVAudioEngineSegmentRecorder` and `FakeSegmentRecorder` conform (the fake feeds silent samples of the length `feed(frames:)` gets).
- **Engine (`Iris`, `LivePreviewEngine`):** `isAvailable(for:)` and `transcribe(_:locale:)`. Production `SpeechAnalyzerPreviewEngine`; fake `FakeLivePreviewEngine`
  (a script of volatile, final and failure steps, advanced by the audio that arrives). `LivePreviewModel` (`@MainActor @Observable`) consumes it: volatile text
  replaces, final text is appended (the last 600 characters are kept), an error clears the preview and it stays off for that take. `TakeModel` starts it with the take
  (`starting`, `recording`, `paused`; not for a thread's hold-to-talk) and ends it at `stopping`, `idle`, `failed`; `TakeController` carries the `LivePreviewSource`
  (tap + engine + locale), `nil` means no preview. The view is IrisUI's `LiveTranscript` (settled text primary, still-changing text secondary, the newest lines
  in view; nothing in the compact banner).
- **Language:** the device's (`Locale.current`), mapped with `SpeechTranscriber.supportedLocale(equivalentTo:)`; German is never assumed. **Available** means:
  `SpeechTranscriber.isAvailable`, the locale is supported, and it is in `SpeechTranscriber.installedLocales` (compared by BCP-47 identifier). **The app never starts a
  model download** (no `AssetInstallationRequest`): a missing model is just no preview. (Apple documents `AssetInventory.status` as advisory; one report has it say
  `supported` for an installed model, so `installedLocales` is the gate.)
- **Audio into the analyzer:** `bestAvailableAudioFormat(compatibleWith:)` (nil while assets are missing), then `AVAudioConverter` per buffer (`LivePreviewConverter`,
  `primeMethod = .none`): the analyzer never resamples. Input is an `AsyncStream<AnalyzerInput>` (bounded) given to `analyzer.start(inputSequence:)`; the results loop
  starts with it. A cancelled take ends with `cancelAndFinishNow()`, an ended input with `finalizeAndFinishThroughEndOfInput()`.
- **Permissions:** microphone only (the take already holds it). `NSSpeechRecognitionUsageDescription` and `SFSpeechRecognizer.requestAuthorization` belong to
  `SFSpeechRecognizer`; Apple's own `SpeechAnalyzer` samples declare only `NSMicrophoneUsageDescription`. No Info.plist key was added. **Device: unverified.**
- **Simulator:** `SpeechTranscriber.isAvailable` is false there (Apple's sample says it does not run in the Simulator; reports from Xcode 26.0 / 26.1 show an empty
  `supportedLocales`). The adapter is compile-checked; everything around it is tested on `FakeLivePreviewEngine`. Device proof: `docs/spikes/device-checklist.md`.
- **Cost:** the model runs outside the app's memory space (Apple); the app pays for one extra sample copy per tap buffer, one conversion and the bounded streams.
  Apple publishes no CPU, battery or model-size figure (one blog says 200 MB or more per language), and none on cellular / Low Data Mode behaviour of the download,
  which the app never triggers. The system caps simultaneous analyses (`insufficientResources`, treated as any error: no preview). **Unmeasured on the phone.**
- **Research (2026-10-31, `agw research`, deep):** German is in the shipped language set and Apple's Voice Memos lists it (iPhone 12 or later); `isAvailable` is false on
  iPhone 11 and SE 2; iOS 27 adds `AnalyzerInputConverter`, `CaptureInputSequenceProvider` and `AssetInputSequenceProvider` (27.0+, Xcode 27 SDK; not used, the app
  targets iOS 26 and feeds its own engine tap). WWDC25 277 preset names (`offlineTranscription`, `progressiveLiveTranscription`) were renamed before shipping; the code
  uses the initializer with explicit `reportingOptions: [.volatileResults]`. Unverified: model size per locale, cellular policy, CPU on iPhone, `de_AT` / `de_CH` membership.
- **Stop button (Wave 18 I5 follow-up):** the take screen's Stop is an opaque `Theme.Status.bad` disc with `Theme.Surface.background` for the glyph (white on the dark
  scheme's salmon red was 2.4:1, and the 0.82 opacity lowered it further). The banner's Stop still has the old fill (I3).

### Notifications

- **Registration** (`PushRegistrar`, `PushAppDelegate`; built Wave 21 P1): once a connection is saved (never on a first launch before it) the app
  registers the `MEMO_DONE` category (Reply, Reply by voice, Play; the content extension declares it), asks for alert, sound and badge once, and calls
  `registerForRemoteNotifications()` on every launch. The hex token goes through `devices/register` with `apnsEnv`: `sandbox` on a Debug build
  (`#if DEBUG`; Xcode development builds talk to the sandbox host), `production` on Release (TestFlight, Wave 22). It is sent again only when
  the token, the environment or the server changes, and a failed send is retried on the next foreground. The simulator has no APNs: the failure is
  an info-level `push.register_failed` and nothing else. Events (`push.authorization|token|registered|register_failed`) never carry the token.
  The push-to-start token comes from `Activity<MemoAttributes>.pushToStartTokenUpdates`.
- **Device signing:** `make device` signs with the paid team by default, headless (`-allowProvisioningUpdates` with the App Store Connect Team key
  from `op://mini/apple-developer`, written to a 0600 temp file for the build only), so `aps-environment` and the App Group are in the build.
  `DEVICE_SIGNING=personal` stays as the free-team fallback without both entitlements (AGENTS.md "Device").
- **Categories:**
  - `MEMO_DONE`: [Reply] [Reply by voice] [Play], all `.foreground` (a notification action cannot run an `AppIntent` itself); the tap on the alert is the open.
  - `NotificationRoute.route(actionIdentifier:userInfo:)` (pure) maps the action and the payload's top-level `memo` id: tap → open the conversation, Reply → open with the keyboard up, Reply by voice → open with `focus=voice`
    (after the open, `ConversationRouter.startVoiceReply` starts a foreground Hermes take bound to the memo's thread, `source: "notification"`, once per request; a memo without a thread yet opens with the keyboard instead and logs `ui.route` `voice=false`), Play → `PlaybackIntents`' `playReply`, falling back to opening the conversation when the reply cannot be played.
    `PushAppDelegate` is the notification center's delegate (set in `didFinishLaunching`, both methods on the main actor: Issue 211).
  - Foreground: `willPresent` shows banner and sound unless the notification belongs to the conversation on screen (`ConversationPresence`, set by `ThreadView`; matched by the memos of the open conversation, since the payload's `thread-id` is the constant `memo`).
- **Deep link** `iris://memo/<id>[?focus=keyboard|voice]` (`ConversationLink` in `IrisCore`, scheme `iris` in the app's `CFBundleURLTypes`): the notification actions, the Live Activity (`Link` and `widgetURL`) and `onOpenURL` all end in `ConversationRouter`,
  which holds one pending request until `RootView` resolves it (History's list, else `GET /v1/memos/:id`), then closes the composer sheet, selects History and pushes the memo on its `NavigationStack` (a running take is left alone;
  a memo that is not a conversation opens its detail; an unresolvable or deleted memo is dropped and logged as `ui.route` `opened=false`). Unit-tested; UI-tested with `-IrisOpenURL` on fakes.
  Device-unverified: the Lock Screen actions, Play from a suspended app, the Live Activity `Link` (and in the expanded island), the suppression of the foreground banner (device checklist N-1 to N-6).
- **A take bound to a thread** (Issue 712 part B): `TakeRequest.threadID` makes the memo continue that thread (the outbox item carries it into `CreateMemoRequest.threadId`, for any voice item); `TakeRequest.holdToTalk` alone marks a thread's hold-to-talk (set only by `OutboxVoiceReplyCapture`), which has no take screen, banner or preview. A bound take with `holdToTalk == false` is a full take (screen, banner, preview, Live Activity, Stop/Pause/Switch input).
  `TakeController.start(mode:threadID:source:activityFirst:)` takes the thread; a take already running still wins and is returned. The continue-the-conversation rule is `TakeThreadBinding.threadID(for:presence:)`, used by `CompositionRoot.startTake` (Record row aside, which has no thread: the Control, Siri, Shortcuts, Action button): a Hermes start while a conversation with a known thread id is on top continues it; History, Stats, Settings, a conversation without a thread id yet and Transcribe start a new memo. Device-unverified: checklist N-7, N-8.
- **Content extension:** headline, kind chip, the condensed answer (Textual
  markdown), and an inline [Play] using the shared player.

### Screens

| Screen | Content |
|-|-|
| History | Tabs History · Stats · Settings (no Threads tab). Memo rows (kind chip · state · headline · relative time, step-progress dashes while in flight), day sections, search (one bottom row, `HistorySearchBar`: a glass capsule, the round filter button with its count badge and the round compose button, all 44 pt, floating above the tab bar as a bottom `safeAreaInset`), a bottom-sheet filter (View: Favorites, Threads, Archived; Kind; State) and no chip row; the navigation bar is hidden and there is no title block (Wave 22 U1: the tab bar says where you are; Stats, Settings and Diagnostics lose theirs too, content starts under the status-bar scrim), native swipe actions (done/favorite, archive/delete with a 5 s undo), pull to refresh, SSE live updates, the compose button in the search row opens the composer |
| Memo detail | Since issue 680 only a transcribe-mode or deleted memo opens it (a Hermes memo opens the Thread; its Details are the per-turn `MemoDetailsSheet`); no reply bubble, no reply action. Order (Wave 22 U1): header (headline, kind chip, one meta line: day · time · cost), then what was said as one bubble (the transcript, right, accent tint) with the recording's compact player under it (collapsed to "Recording m:ss" with play, opens to the scrubber and 10 s back; with no transcript yet the player stands alone), a pending bubble with the step dashes while it transcribes; then **Details**: a line, collapsed unless the memo failed, that opens to Copy transcript, the actions line, the step waterfall (one `duration · cost` chip per step, money in the user's locale: two decimals from a cent, four below; faster/slower vs the stats baseline only above a sample threshold; attempts; a failed optional summarize as a warning row; [Retry from step]) and the ids (memo, thread, device). long press on a bubble copies it as plain text; the icon-only retry stays at the bottom; SSE refresh |
| Composer | Typed memo: mode picker (Auto, Journal, Hermes, Tab, Chat), text, send via `POST /v1/memos/text`; a new memo only (a reply is typed in the Thread's bar) |
| Stats | Volume per route per day / week (Swift Charts), tiles, per-route trends, from `GET /v1/stats` |
| Thread | One conversation as a rendered document (`GET /v1/threads/:id`), opened by the History row of any Hermes memo (Wave 15 I2, issue 680, "Thread view" above): question and answer turns, a pending answer with the step dashes, a Details button per memo (the Details sheet), and the reply bar (text field, hold-to-talk, locked recording) from the first turn |
| Record | Wave 15 I4. **Start from any screen:** the record control is the tab bar's bottom accessory (`RecordRow`: Hermes, Transcribe and Text buttons, see "Two modes and the kind chip"); memo detail and thread hide the tab bar, but that does not hide the accessory (Apple DTS, iOS 26.1: it stays across the app), so it would sit over their bottom actions and swallow taps: `DetailActionBar` and `ThreadReplyBar` register through `.hidesRecordAccessory()` into a counted `RecordAccessoryPresence` (injected by `RootView`), and `tabViewBottomAccessory(isEnabled:)` takes the control off while one is shown (iOS 26.1+; on 26.0 it stays, **not verified on a device**). Their banner still shows. A take opens the full `TakeScreen` (mode, timer, level waveform, mic list, pause, Stop, discard with a confirmation); minimizing (chevron) leaves a compact **`TakeBanner`** (dot, running time, mode · mic, "N sending", Stop: an opaque `Theme.Status.bad` disc with a `Theme.Surface.background` glyph, as the take screen's) pinned under the navigation bar of every screen (`.takeBanner()`), and tapping it returns to the full take (it comes and goes with an animation only while the scene is active: the device's 10 s scene-update watchdog hit an animated navigation-bar layout of a backgrounded scene when a take ended from the banner, Wave 17 D2; Stop only ever suspends the main actor, `StopOffMainTests` holds a hung recorder). `TakeModel` follows `CaptureSession.updates()` and the outbox; a pause moves the timer's start forward so it counts recorded time. Leaving the app needs no hand-over: the take's Live Activity is requested at the start, so the Lock Screen card and the Dynamic Island carry it from there |
| Settings | Diagnostics (copy a memo id, animated "Copied"), Connection (server URL + device token in the Keychain; the status row is the health probe from when Settings appeared **and** `HistoryModel.link`, what History's authenticated event stream and list loads last saw: "Connected" is never shown for a server that stream cannot reach; a dropped stream reads "Unreachable" with "Server not reachable — is Tailscale on?", a 401 "Token rejected", a failed probe that traffic has since overruled "Connected"; `ConnectionStatusLine`; "Not configured" until saved), Playback (spoken replies toggle), Microphone (the active route's rule), outbox section (the queue of whole items from `OutboxService`: kind, age, state, a retry time or the reason it stalled, retry now and discard; live through the outbox's change stream). Later: default mode |

## 5. macOS app (`IrisMac`)

- **Window and hotkey:** `MenuBarExtra` with `.menuBarExtraStyle(.window)`,
  `LSUIElement`. The global hotkey goes through `KeyboardShortcuts` 3.1.0
  (Carbon `RegisterEventHotKey`: no Accessibility or Input Monitoring prompt,
  works in the sandbox), decided in `docs/research/2026-10-31-mac-hotkey.md`.
  No `CGEventTap` fallback: a listen-only tap costs an Input Monitoring grant
  and an active one Accessibility, for features (modifier-only keys, media
  keys) the take does not need. `NSEvent` global monitors reportedly crash on
  macOS 26 and are not used. The default is **Control-Option-M**, recorded by
  the user in Settings (`KeyboardShortcuts.Recorder`, stored in `UserDefaults`
  by the package). Control-Option-Space is *not* free: it is the system's "next
  input source". The default is also none of the owner's dictation keys (Fn,
  double Fn, Cmd-Shift-Space style). A combination another app holds fails
  silently in Carbon; Settings shows "This key is not active" when
  `KeyboardShortcuts.isEnabled(for:)` is false.
- **Panel:** a floating non-activating `NSPanel` (`NonActivatingPanel`:
  `.borderless` + `.nonactivatingPanel`, floating level, every Space and over
  full-screen apps, top centre under the menu bar) for the take, showing the
  timer (`ElapsedTimerText`), the level (`LevelWaveform`, the last 36 buffers),
  a mic picker and Stop / Cancel. A refused microphone, a missing connection or
  a failed start leaves a sentence in the same panel (with "Open Settings" for
  the microphone) until closed.
  *Keys (Wave 19 M1):* `canBecomeKey` is **true** (a borderless window refuses
  key status otherwise; `canBecomeMain` stays false) and `becomesKeyOnlyIfNeeded`
  stays false, but the panel is shown with `orderFrontRegardless`, which changes
  neither the key nor the main window: the app in front keeps its keystrokes
  until the user clicks the panel. A click makes it key without making Iris the
  active app (the `.nonactivatingPanel` bit is set at init; AppKit tags the
  window then and never again, so it cannot be toggled on a live panel). That
  gives the Microphone menu a key window to open from, Return = Stop
  (`.keyboardShortcut(.defaultAction)`) and Escape = Close on a message
  (`.cancelAction`); Cancel of a running take has no shortcut, so a stray Escape
  cannot drop a recording. Researched (`agw research`, Apple's `NSPanel` /
  `NSWindow` pages, philz.blog on the init-only bit, Apple DTS thread 826308) and
  checked on the mini by `RecordingPanelKeyTests`: the panel is non-activating,
  can be key, is not key after being shown, and after `makeKey()` it is key while
  `NSWorkspace.frontmostApplication` is still the app in front. **Found:**
  `NSApp.isActive` reads `true` after `makeKey()` (the research report expected
  `false`); what that means for where the keystrokes go, and that the app behind
  stops getting them while the panel is key (key-focus theft, by design), only a
  person at a MacBook can show: device-checklist M15.
- **Capture (Wave 18 M2):** the same `IrisCapture` package. macOS has no
  `AVAudioSession`: `MacAudioSessionController` is a no-op, and
  `DirectoryRouteManager` (over the `AudioDeviceDirectory` port;
  `CoreAudioDeviceDirectory` reads Core Audio's hardware object and listens for
  device and default changes) is the `RouteManager`: the available inputs are
  the recording devices (hidden ones left out), the current input is the system
  default, and **picking a microphone sets the system default input**, which
  the engine follows (`AVAudioEngineConfigurationChange` rolls the segment).
  The default before the first pick is kept and put back when the take ends,
  however it ends, a start that throws after the session applied a mic rule
  included (`setPreferredInput(uid: nil)`), and only while the default is still
  the device Iris set: a default somebody else chose mid-take is left alone. The
  original is also written down (`RecoveringRouteManager` wraps the route
  manager; `UserDefaults`, `{original, replaced, chosen}`) **before** every pick of a
  take changes the default (`original` is kept from the first pick, `replaced` is the default this pick replaces, `chosen` the device it sets), and
  cleared when the restore has run. A kill
  mid-take leaves the record; the next launch (`RecoveringRouteManager.recover`,
  run by `MacCaptureStack.production`) puts the original back under the same
  rules as the in-process restore (only while the default is `chosen` **or** `replaced`, because a kill can land on either side of the
  system call), else drops it; an original that is not attached yet (a USB or Bluetooth microphone that comes up after login)
  keeps the record (`pending`). The restore at the end of a take clears the record only when this process changed the default, so a take
  that picked nothing leaves a record from an earlier run (a recovery that failed or is pending) for the next launch. The recovery's failure is not logged with the error (it can name a
  port); the outcome is the `audio.input_recovery` record. A
  restore that fails keeps the record for the next launch. `routeChanges`, the directory's `changes` and the engine's
  levels, failures and mic list are broadcasts (`Broadcast`): every read is its
  own subscription, because the capture session and the panel both listen and an
  `AsyncStream` ends for everyone when one consumer stops. Per-device mic rules are local
  (`UserDefaults`, fingerprint = the default output's UID). The engine is the
  same `AVAudioEngineSegmentRecorder` (16 kHz mono AAC, 10 s segments); the
  outbox is the iPhone's `CaptureStack` over `JSONFileOutboxStore` in the app
  container and `APIOutboxUploader` over a `ReconfigurableAPIClient` the Mac's
  connection change re-points (`MacCaptureStack`, same sources compiled into
  both targets). A take is mode Hermes by default (the hotkey, the popover's Hermes button); the popover's Transcribe button starts a Transcribe take.
  `RecordingPanelModel` is the state machine (`idle → starting → recording →
  stopping → idle`, `failed(reason)` side state); a press or button while a
  start or stop runs is dropped, a microphone pick is queued, and a recorder
  failure mid-take stops the take, keeps what closed and says so. The model
  drives a `TakeEngine` port (`CaptureTakeEngine` in production, scripted
  `FakeTakeEngine`), a `MicrophonePermission` port and a `TakeHotkey` port; the
  outbox is opened at launch and again on a connection change, so a take made
  offline or cut short is sent next time. The memo the outbox creates shows in
  History at once (the created-memo log) and by the SSE after that. Cancel
  follows the iPhone's lifecycle: the memo the session discarded is forgotten
  (`CreatedMemoLog.forget` → `HistoryModel.hide`, the hidden set persisted), its
  server `DELETE` settling unhides it, and the launch reconcile drops hidden ids
  with no `DELETE` queued. A stop that returns a result with `failure` (the
  recorder failed, or stopping timed out after earlier segments closed) is
  `TakeEnd.partial`: the memo is sent with what closed, and the panel says the
  recording stopped early. **Server binding (Wave 19 M1, the iPhone's
  I1 design, §4):** the outbox binds every item to the server configured when it is queued (`MacCaptureStack` passes
  `CaptureStack.Parts.serverKey` = the `ReconfigurableAPIClient`'s key, `ConnectionCredentials.serverKey`); after a connection change
  work for another server is held back and goes out when that server is configured again, and a call made for an item that finds
  another server configured throws `WrongServerError` instead of sending. The root's `ServerKeyBox` holds the saved connection's key
  and is the `serverKey` of every `HistoryModel` it makes (the client is wrapped by `StreamTappingClient`, so the model cannot read
  it): an answer that started under another server is dropped, and the created-memo log's `setServerHandler` hands `origin` to
  `insert(_:origin:)`, so a memo created on another server is not shown. `ConnectionBoundClient` (a connection epoch counted by
  `MacCaptureStack.reconnect`) stays as a second guard: a create answered after the switch is refused as a transport error.
  No log line carries a device uid.
- **Notifications:** live SSE `/v1/events` for status, local notifications
  while it runs, and APNs registration for when it is asleep.
- **First slice (Wave 18 M1, no capture yet):**
  - *Composition:* `MacCompositionRoot` picks the adapters once. `-IrisFakeData` runs the fake API with the sample
    memos, an in-memory credential store (an unsigned build has no Keychain, `-34018`) and a notification poster that
    records; otherwise production, with the iPhone's `ReconfigurableAPIClient`, `ConnectionModel` and `KeychainCredentialStore`
    (same sources, compiled into both targets). With nothing saved the panel opens on its home page with a connect prompt and nothing loads.
  - *Panel:* a 360 pt wide `.window` popover (`docs/design/mockups/mac.html`, variant `menu`), the quick-access surface and one page
    (`MacHomePage`): the title with a Record button (the same toggle as the hotkey, showing the recorded key), the newest five
    memos as compact rows (`MacMemoRow`: headline on one line, time, status dot and route; a click opens the main window on that
    memo, a context menu for done / favorite / archive / delete, the undo toast), the lines Open Iris, Settings… and Quit Iris, and the
    connection line (`MacConnectionStatus`, from `HistoryModel.link`); with nothing saved it shows a connect prompt that opens the
    onboarding window. Its list is always the unfiltered `root.history`.
  - *Desktop windows:* History, the memo detail and Settings are windows of a desktop app, not popover pages (the owner's review of the
    first version: an iOS view ported to the Mac reads oversized and boxed). The main window "Iris" is a `NavigationSplitView`: sidebar
    (library and conversation filters over `HistoryFilters`), a native `List` of compact rows on the window's own `HistoryModel`
    (day sections, search in the toolbar, Delete, Space plays), and a document-style detail (`MacMemoDetailPane`: headline, one
    metadata line (time · length · cost), the route answer bar for a parked memo, reply, summary, transcript, then Details, a disclosure group
    (collapsed unless the memo failed) with the steps table and the ids, a thread's conversation read
    only; actions in the toolbar). Settings is the native tabbed `Settings` scene (Connection, Recording, General) and the onboarding
    window takes a first connection (Test connection must pass). Type is the macOS scale (11 / 13 / 15 / 18 pt, `Theme.MacTextRole`);
    colours, route dots and wording stay Iris's. `MacActivationPolicy` shows the app in the Dock and ⌘Tab while such a window is open.
    Playback uses a bare `AVPlayer` (`MacAudioPlayer`; macOS has no `AVAudioSession`). Not on the Mac: Mermaid images (shown as code),
    replying inside a thread. The window's list takes the popover's one event stream by mirror (`StreamTappingClient.mirror`), not a second connection.
  - *Live updates:* the list and `HistoryModel.observeEvents()` start at launch, independently of each other (a hung first list
    request does not hold the stream back; its `ready` event reloads the list), whether or not the popover was ever opened, and
    restart on a connection change. The list reloads on every stream reconnect.
  - *Notifications (Wave 19 M1, `MemoNotifier`):* a banner per **transition**, for three kinds: finished (`notified`: route and
    headline, "Done." without a summary), or failed (the title is the memo's kind; an old `needs_route` memo announces nothing). Three feeds, one record (`announced`, the kind each
    memo was last announced as): `memo.updated` / `memo.done` payloads from the open stream (`StreamTappingClient` hands every
    state to the root in stream order; `noteState` is synchronous, so an earlier event never overtakes a later one), the
    `memo.done` payload (its state is on the same stream: there is no separate `History` hook), and the **catch-up** after the stream (re)connects. A state that is not a kind (a retry) clears
    the record, so the memo's next finish is a new banner; a repeated event or a second feed posts nothing. The event's state is
    not the answer: the memo is fetched fresh before posting and judged by that copy. The catch-up fetches the newest 50 memos
    **unfiltered** (History's filters hide memos from its list, not from the banners): the first one of a connection is the
    baseline (what is finished is recorded, nothing announced), later ones announce memos that reached a kind since — ones the
    connection saw running, and ones it never saw that started after the baseline's newest — at most five per catch-up, newest
    first, the rest recorded. Banners never carry the transcript, the reply or the park reason: generic words for parked and
    failed. A fetch or post that fails is tried three times, logged, forgotten. The permission is read again for every memo, and
    the system prompt runs on the side. A memo in flight twice (an event while a catch-up delivers it) is delivered once, and looks
    again fresh when the first delivery is through; a delivery whose memo changed state while its banner was being posted (a retry) does not
    record its kind. Catch-ups run one at a time in the order asked, so a later fetch cannot become the baseline over an earlier one. **Limit:** a memo that finished while the *app was not running* is not announced
    (the baseline records it); the Mac notifier reads the event stream only, the server's APNs alerts go to devices that registered a token.
  - *Connection change:* the connection gets its own client and a new `HistoryModel`; the notifier is cleared (every event, fetch and
    catch-up carries the notifier's generation from when it started and re-checks it after each await, so a task of the old server
    posts and records nothing; a banner the system took while the switch ran is withdrawn again, and the switch withdraws every
    banner of another connection from Notification Center, as does launch); a banner carries its connection id (a digest of the server URL and token, so it survives an app restart
    and changes only with the saved connection) and a click on a banner of another connection is ignored; queued row actions of
    the old list are dropped, and the actions on one memo run in tap order, each on the memo as it is then, so the last tap wins on the server
    (`MacCompositionRoot.perform`); the main window's list is replaced, its selection clears and following restarts.
  - *Open detail:* reloads on each `memo.updated` and on every stream `ready` (`StreamTappingClient`; a list request that
    succeeds during an outage does not count), and a response overtaken by a newer load is dropped.
  - *Rows match iOS (Wave 19 M1; the popover's History page this describes is gone, the main window uses the macOS scale):* the list applies the iPhone list's spacing roles (`Theme.Spacing.rowVertical` and `screenMargin` as
    row insets, `screenMargin` header insets, `sectionTop` / `sectionBottom` around the day label, header and row minimum heights 0, the search field on `screenMargin`), so a row and its inset separator sit on
    the same 20 pt margin as `HistoryView`'s. By design not the same: no disclosure chevron (a click opens the detail window), the
    search field is on top (the iPhone's is a bottom bar), and `listSectionSpacing` does not exist on macOS (a plain list has none).
  - *Proof:* a menu-bar popover cannot be opened without a click and the mini has no Screen Recording grant, so
    `-IrisMacPanelWindow` shows the same panel as a regular window and `-IrisMacSnapshot <dir>` has the app write PNGs of its own
    windows (the popover, the main window as a document, as conversations (running, answered, with a diagram), the New memo page with and without text and a memo just sent, the Settings tabs, onboarding, the recording panel and its refused message) and quit (any further launch flag, such as `-IrisMacStalled`,
    goes **after** `-IrisMacSnapshot <dir>`: between `-IrisMacPanelWindow` and it, the panel window is not created); snapshot mode only exists on the fake composition. Unit tests: `IrisMacTests`,
    hosted in the app (launched with `-IrisFakeData`), run by `make check-apple`.
- **Signing:** a stable identity. Ad-hoc signing resets TCC
  on every build (the microphone grant is keyed to the code signature). The
  app is **not sandboxed** (Wave 22 M2; Developer ID, Sparkle swaps the bundle in place) and its entitlements are the Hardened
  Runtime `com.apple.security.device.audio-input` only: no App Group (nothing reads it on the Mac), no network entitlement, so
  it signs with an Apple Development or Developer ID identity without a provisioning profile and its grants survive rebuilds;
  the unsigned CI and `check-apple` builds never record. Leaving the sandbox moved the data from the app container to
  `~/Library/Application Support/Iris` and the old signature's Keychain item may not be readable (unverified: expect an access prompt or a re-entered connection once). The microphone prompt and a
  real take need a Mac with a microphone and a person: hands-on rows in
  `docs/spikes/device-checklist.md` ("Mac hands-on rows").
- **Updates (Wave 22 M2):** Sparkle 2.10.x (floor 2.9.6) through SPM, `SPUStandardUpdaterController` behind the `UpdateEngine`
  port (`Updater` is the observable the menu items read; `SparkleUpdateEngine` is the adapter, `ScriptedUpdateEngine` the fake).
  The root owns the updater only when `IrisMacApp` hands it an engine, which it does outside `-IrisFakeData`. Info.plist:
  `SUFeedURL` (the `releases/latest/download/appcast.xml` URL of this repo), `SUPublicEDKey`, `SUEnableAutomaticChecks`, and
  `CFBundleShortVersionString` / `CFBundleVersion` from `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`; the release script sets
  the latter to the commit count, so Sparkle always sees a growing build. "Check for Updates…" is a popover line
  (`MacMenuLine`, id `mac.menu.update`) and a `CheckForUpdatesButton` in Settings > General, both disabled while
  `Updater.canCheckForUpdates` is false and absent without an updater. No custom `NSUpdateSecurityPolicy`.
  Releases: `make mac-release` (`scripts/mac-release.sh`; AGENTS.md "Mac releases") archives, signs, zips with `ditto`, runs
  `generate_appcast`, verifies the EdDSA signature and creates a GitHub release with `IrisMac-<version>-<build>.zip` and
  `appcast.xml` (drafts are never `releases/latest`). The EdDSA key lives in the mini's login keychain; the tools read it from
  `--ed-key-file` because the keychain prompt hangs headless. Sparkle's helpers (Autoupdate, Updater.app, the XPC services) are
  shipped ad-hoc signed, so a Developer ID release re-signs them inside out, then the app, before `notarytool`. Proven on the mini
  (2026-11-05): notarytool Accepted, `stapler validate`, `spctl -a -vv -t exec` = Notarized Developer ID. *Open (needs the MacBook):*
  first install without Open Anyway, an update with no admin prompt, and `xattr -l` on the updated bundle.
- **Outbox panel (Wave 19 M1):** a strip under the panel header on every page, only while the queue holds something or cannot
  be opened or saved (`MacOutboxStrip` over `MacOutboxModel`). It reads the iPhone's `QueuedItemSource` (`OutboxService`, compiled
  in; no second model of the outbox): a count ("2 of 3 could not be sent"), the first stalled item's reason, and per item the
  iPhone Settings row (`OutboxItemRow`) with Retry now / Discard (a queued server delete says "Stop trying"). It opens by itself
  while an item is stalled, three rows show whole and more scroll in 200 pt. A queue that cannot be opened or saved says so in
  the same words as Settings, and a Discard that did not reach the queue says so. The strip is followed from launch to quit
  (`begin()` starts the observation once), so a take made before a connection was saved shows. Fakes: `ScriptedQueue`
  (`-IrisMacStalled` seeds a stalled upload, a retry backoff and a queued removal for the screenshot).
- **Telemetry (Wave 19 M1):** the Mac is on the device log and the relay like the iPhone (§8): the iPhone's `DeviceLog`,
  `DeviceLogCaptureEvents`, `ObservedSegmentUploader` and credentialed transport are compiled into `IrisMac`, and `MacTelemetry`
  builds the log with `service.name=iris-macos` (crash file `telemetry.jsonl` in `~/Library/Application Support/Iris`; under `-IrisFakeData` the
  records stay in memory). The capture session, the recorder and the uploader report through it (`take.phase`, `capture.*`,
  `outbox.segment.upload`, `outbox.complete.sent`; trace id = memo id without dashes), `take.phase` names the control that asked
  (`source`: `hotkey` or `panel`). Mac-only records: `mac.panel` (the panel's phase, and a failure's enum name), `mac.hotkey`,
  `audio.input_switch` (`pick` / `restore` and whether it worked) and `audio.input_recovery` (`restored`, `dropped`, `failed`),
  `notify.mac` (`posted`, `withdrawn`, `catchup` with the banner's kind or counts), `outbox.user_action` (`retry`, `discard` and
  the item's kind, on the memo's trace) and `app.lifecycle` (`launch`, `quit`). **Never in a record:** a transcript, a reply, a
  park reason, a banner text, a token, a URL, a device uid or name (a test scans the records for the memo's words). A server switch
  rebinds the records (`server.id`), so the old server's are never sent to the new one.

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
**IrisCore and the Hermes-decides wire.** `Memo` decodes `kind` (`String?`) and `actions` (`[String]`, empty when absent); `routeReason`, `routeSuggestion`, list `pinned`, `routeMemo`, `herd`, `ThreadKind` and `LiveActivityPhase.needsRoute` are gone. `MemoMode` is `hermes`/`transcribe` (any other wire value reads as `hermes`); `MemoState.needsRoute`, `MemoStep.route` and `Memo.route` stay so old rows decode. `ListMemosQuery` sends `kind` (the memo kind, exact) and `thread=true` (conversations). `Stats` is per memo kind (`perDay`, `stepMedians`, `costPerKind`; a null kind is a transcript or an unclassified memo). `MemoThread.kind` is a plain string the app ignores. Fixtures with a legacy mode carry `hermes`; a separate test decodes the legacy modes.

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
  - Metrics as named log events: `memo.completed{kind, audio_s, total_ms,
    cost_usd}`, `stt.latency`; the Hermes adapter logs `hermes.meta_invalid{memo_id, reason}` when a reply has no valid `iris` block.
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
  - On iOS, MetricKit crash and hang diagnostics are relayed on the next launch (`metrickit.*`, below).
- **Device events (iOS).** Device testing does not depend on the owner narrating what he saw: every capture, route,
  interruption, outbox, intent and Live Activity event goes through one `DeviceLog` and is **an `os.Logger` line and a
  relayed log record** (`service.name=iris-ios`, `Body` = the event name).
  - **Every record** carries `event.name`, `seq` (per-process counter), `uptime_ms` (monotonic since launch, so order and
    durations survive a phone clock step), `app.pid` (a new pid mid-take is the relaunch), `memo.id` (= the trace id, 32 hex,
    when the event belongs to a memo; the log's `traceId` is the same) and `run.id` (the word typed once in Settings >
    Diagnostics, unset otherwise); ambient `app.state` and `process` (`com.jkrumm.iris`). `service.version` is the build's
    `IRIS_BUILD_SHA` (a git sha when the build passes one, otherwise `dev`), `device.name` the phone. The console line has the same name as its category
    prefix: subsystem `com.jkrumm.iris`, category = the part before the first dot.
  - **Delivery:** records are written to the crash file (`FileTelemetryStore`, Application Support) as they are recorded, sent at
    launch (what a killed run left), every 10 s, and on background under a background-task assertion.
    - A record is in the file before it is acknowledged, so a kill loses only the events still queued in memory (microseconds).
    - The stored queue of the last run is loaded before the first new record is numbered: no reused `seq`, and no acknowledgement
      deleting an older record.
    - A torn last line is cut off before the next append. One flush runs at a time: a flush that finds one running waits for it
      (and runs one more pass if nobody has started another), so no batch is sent twice and an acknowledgement never removes a
      batch another send still holds. The load of the stored queue is shared the same way: a record waits for it before it is
      numbered, and a flush that races the launch recovery sends each stored record once.
    - **Bounded in time.** A send is cut off after 20 s (`RelayExporter.sendTimeout`; the batch is kept and retried, the request
      itself times out at 15 s), and the flush on backgrounding holds its background-task assertion for at most 20 s
      (`DeviceLog.backgroundFlushBudget`), ending it also in the system's expiry handler and from a deadline task of its own, so neither a send that never
      answers nor a flush that joined a running one (its wait is cancellation-aware) can hold the assertion past it.
    - **Before the first unlock** the crash file is unreadable (it is written with protection class
      `completeUntilFirstUserAuthentication`, so a background launch with the screen locked can write once the phone has been
      unlocked since boot, never before). Then nothing is lost and nothing crashes, by one rule: **the store is read before it
      is written.** The first record waits for the first load, so it is numbered after the stored entries. While the file has
      not been read, this run's records are memory-only: no append, no trim, no removal by sequence (the file cannot say which
      sequences it holds). The next successful load renumbers them above the stored maximum, persists them, and only then marks
      the queue recovered; a failed persist leaves it unrecovered and the next flush retries. A load that finds a send holding
      entries waits for the next flush rather than renumber under it. Sequences never come from the clock.
    - Each record carries the `server.id` (a hash) of the connection it was recorded under. The transport delivers a record only
      to that server and drops the rest, **counted in `dropped`** of the batch that goes out: a queue written for one server is
      never handed to another after a switch, and the loss is visible. While the current server is unreachable the send fails and
      the whole batch stays: nothing is dropped for being unreachable.
    - `dropped` reports overflow (2 000 records) plus the records left behind for another server.
    - `take.phase.source` is the control behind the latest take command; once that command is 60 s old, a phase change reports
      `system` (an interruption, a failure) instead of crediting an old press.
  - **Privacy:** no transcript, reply or token: a key naming one is dropped before it is recorded, a string is cut at 240
    characters, port uids are not logged (an attribute whose lowercased key ends in `uid` is dropped as a net: `port.uid`, `input_uid`, `portUID`, and deliberately also `fluid`), and a port name that can carry a person's name ("Anna's AirPods") is a short hash;
    only the phone's own generic port names stay. An error is logged as its type (and an enum's case), never its message or payload:
    server text and file paths do not reach a record. Public repo: no real value in tests or docs.
  - **Records:**

    | `event.name` | Attributes |
    |-|-|
    | `app.launch` | `launch.reason` (`user`\|`background_launch`), `previous.phase` (last scene phase of the run before), `previous.exit=unknown`, `outbox.state` (`available`\|`unavailable`\|`unreadable`), `outbox.items` (only when available: never a zero for a queue that could not be read), `outbox.quarantined_files`, `mode` |
    | `outbox.state` | `reason=recovered`, the attributes of `app.launch`'s queue part, when a queue that launched closed or unreadable opens |
    | `app.lifecycle` | `scene.phase`, `reason` |
    | `take.phase` | `phase` (`starting`\|`recording`\|`paused`\|`stopping`\|`failed`\|`stopped`), `source` (the control that asked last: `app`\|`intent`\|`island`\|`thread`, or `system` when no command in the last 60 s), `mode`, `input.name` (generic names of the phone's own ports; any other name is a short hash), `failure` |
    | `capture.session.error` | `call` (`setCategory`\|`setActive`\|`setActive(false)`\|`installTap`\|`engine.start`), `error.domain`, `error.code`, `error.fourcc` (`561145187` is `!rec`, `560557684` `!int`), `error.type`, `engine.running`, `session.category`, `session.mode`, `session.options`, `session.other_audio_playing`, `session.sample_rate`, `session.io_buffer_ms` |
    | `capture.tap.install` | `rate`, `channels`, `hardware_rate`, `valid`, `generation`; written to the crash file and flushed to disk *before* the call that can abort returns (a blocking write, bounded to 500 ms), so the last one before a gap in `seq` is the one that did |
    | `audio.route_change` | `reason`, `route.prev`, `route.current` (`portType:name,…`, names as for `input.name`), session snapshot |
    | `audio.config_change` | `engine.running_before`, `input.rate_before`, `input.channels_before`, `generation`, session snapshot |
    | `audio.interruption` | `type` (`began`\|`ended`\|`resume`\|`resume_skipped`), `reason`, `options`, `should_resume`, `resume.result`, `api` |
    | `capture.gap` | `ms`, `reason` (`pause`\|`interruption`\|`media_services_reset`\|`config_change`), `frames_lost` (`ms` at 16 kHz) |
    | `capture.segment.closed` | `index`, `bytes`, `seconds`, `reason` (`rotate`\|`route`\|`pause`\|`stop`), `closed_ok` (the file has bytes), `disposition` (`queued`\|`discarded`\|`late`) |
    | `take.discarded` | `segments` (closed so far); the take was dropped on purpose, so its segments never upload |
    | `outbox.segment.upload` | `index`, `attempt`, `status` (`ok`\|`permanent`\|`transient`\|`error`), `ms`, `error` (the error's type, never its message) |
    | `outbox.complete.sent` | `segment_count`, `status`, `ms`, `error` |
    | `capture.quarantine` | `file`, `bytes`, `has_moov` (per set-aside file at launch) |
    | `capture.level` | `rms_db`, `peak_db` (dBFS, twice a second while a take records) |
    | `intent.perform` / `intent.result` | `intent`, `process`, `handler.present`, `mode`, `can_continue_in_foreground`, `press_lag_ms`; `ok`, `error` (type and case only); both carry the take's `memo.id` (Start: the new memo, on its result) |
    | `liveactivity.request` / `.update` / `.end` | `activity.id`, `phase`, `ok`, `error`, `push` (token or none), `dismissal` (`immediate`\|`after`), `reason` |
    | `liveactivity.snapshot` | `reason` (`launch`\|`launch_swept`\|`foreground`\|`background`), `count`, `states` (`id:state;…`), `age_s` (`id:seconds;…`) |
    | `metrickit.crash` / `.hang` / `.cpu_exception` | `app.version`, `window.end`, `call_stack` (innermost frames, `binary+0xoffset`), `exception.type`, `exception.code`, `signal`, `termination.reason`, `hang_ms`, `cpu_ms` |
    | `ui.screen` | `screen`, `shown` |

  - **Read it:** a take's device timeline sits next to its server timeline in HyperDX (skills `device`, `memo-debug`): the
    memo id without dashes joins them; order by `seq`, not by timestamp. A segment with `capture.segment.closed` and no
    `outbox.segment.upload` is a data-loss alarm visible while the take still runs.
  - **The widget extension logs to `os.Logger` only.** The server URL lives in the app's `UserDefaults` and the extension has no
    other way to reach it (the App Group is on for paid builds, but no relay code reads it from the extension). `StartMemoIntent` and the Live Activity buttons are
    `LiveActivityIntent`s and run in the app process, where they *are* relayed; a Record press with no `intent.perform` means the
    app was never reached.
- **Propagation:** the audio door doesn't accept `traceparent` (factory
  ADR-006 plans it), so Iris spans carry the memo id as an attribute on every
  downstream call. Once ADR-006 lands, `traceparent` is added.
- **Cost:**
  - STT/TTS spend is recorded by the audio door as a run per request (caller `iris`, from the bearer token's
    name); the `agw-run-id` of each call is on the Iris span and log line (`agw.run_id`), so a memo's trace
    leads to its run record;
  - the Hermes turn's usage and cost come back on the delivery and are stored on the `act` step row;
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
  - TestFlight internal (Wave 22 P2): `make testflight` runs `xcodebuild archive`
    (Release, `generic/platform=iOS`, `CFBundleVersion` = `<git rev-list --count
    HEAD>.<UTC epoch hours>`, never committed: strictly increasing per upload,
    so the weekly same-sha rebuild is not a repeated build number) and `-exportArchive` with `apple/ExportOptions.plist`
    (`method app-store-connect`, `testFlightInternalTestingOnly`, `destination`
    `export` for a local `.ipa` or `upload` for App Store Connect), both signed
    headless with the App Store Connect Team key from `op://mini/apple-developer`
    (`-allowProvisioningUpdates`, cloud signing; a 0600 key file deleted on every
    exit). The upload is the export's `destination upload`; `altool` is not used.
    The Release build registers its APNs token as `production`;
  - the deploy poller starts the build detached when `apple/**` changed on a
    green master, plus a weekly rebuild (builds expire after 90 days); the
    internal group's automatic distribution installs it on the phone, and
    `make device` stays for debugging (AGENTS.md "Release hooks").
  - First upload 2026-11-06: build `687.498322` of app record `Iris Agents`
    reached `processingState VALID` and the internal group `Internal` (`IN_BETA_TESTING`)
    without a review; nothing is listed in the App Store. The first attempt failed in
    `-exportArchive` for want of an app icon and because the Info.plists hardcoded
    `CFBundleVersion` 1 (the archive's own version must equal the exported one).
  - `make device` (free or paid team, `devicectl`) stays for debugging.
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
  the audio door (STT/TTS) and Hermes. APNs payloads carry headlines
  only, never full transcripts; when Hermes sent no valid `iris` block, the headline is the
  first 60 code points of the transcript (owner-confirmed, Wave 16); the same rule gives a `transcribe`-mode memo its headline, which is
  always the transcript's start.

## 13. Risks and unverified

| Risk | Plan |
|-|-|
| A Live Activity start from a control intent may need the foreground (one forum report) | S1 (Wave 17 D2, iOS 26.6.1): the control starts nothing at all, with no visible error; not yet the "needs the foreground" refusal, more likely the missing handler in the extension process. I8 fixes it or takes the fallback `openAppWhenRun` + auto-start, accepted by the PRD |
| Built-in mic while connected to the car's Bluetooth is undocumented | S2 on hardware; Wave 17 D2: the AirPods switch crashes the app before the car question can be asked, the car was not run, still open |
| An audio engine cannot restart in the background | Device (Wave 17 D2): resume from the island and one lock case failed with "engine resume failed" and the UI kept counting; a route change to the AirPods (or a start with them connected) aborts the app with an uncaught `NSException` in `installTap`; the take loses its open segment (I7) |
| A segment open at a crash is unreadable | Device (Wave 17 D2): three quarantined segments had no `moov` atom, the seconds were gone. Wave 18 I2: fragmented m4a, a kill keeps all but ~0.5 s (macOS SIGKILL experiment); the device row 8a proves it on hardware |
| Live Activities are server-owned after the hand-over | Without APNs (Personal Team) they stay on "Processing" and hijack the island; I8, and the paid team's pushes must be re-checked in D3 |
| TTS playback from a Live Activity intent while the app is suspended | S3; fall back to opening the app |
| Bun `node:http2` over-dispatch to APNs | Cap in-flight streams (D6); Bun 1.3.14's HTTP/2 `fetch` as a fallback |
| `xcode-27` is a preview CI image | Fall back to `macos-26` (D14) |
| Exact Swift build-setting spellings (default isolation) | Verified in the setup wave against Xcode 27.1 |
| Personal Team cannot sign Push or App Groups; 7-day profiles, 10 App IDs per 7 days | Device builds sign with entitlements minus `aps-environment` and the App Group (`DEVICE_SIGNING=personal`); `DEVICE_SIGNING=paid` (default) signs the tracked files, App Group included (2026-11-05). Verified Wave 17 D1 on an iPhone 15, iOS 26.6.1: build, install and launch work, headless codesign needed no keychain prompt |
| Hermes's `iris` block quality (kinds drift, headlines too long, block missing) | `hermes.meta_invalid` logs and the `kind` spread in Stats; the fix is the Hermes `iris` skill, not Iris |
| Voxtral has no timestamps | Plain transcript in R1–R3; revisit if a synced transcript matters |
