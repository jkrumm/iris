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
- **Processing:** the server concatenates, transcribes (audio-gateway,
  Voxtral), routes (spoken prefix, then agent-gateway `decide`), acts
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
          ▲                                                                                         ├─> audio-gateway (VPS)  STT · TTS
          └──────────── APNs (alert · liveactivity) <───────────────────────────────────────────────┤
                                                                                                    ├─> agent-gateway 127.0.0.1:7705  decide · triage
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
`Notifier`, `Herd`, `DeviceStore`, `StatsStore` (SQLite only, no fake), `AudioStore`, `AudioCombiner`, `Clock`, `Decider`; `Ids` is unused). `Destinations` is the registry
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
```

- **Parking:** only `route` and `act` may park a memo in `needs_route` (a handler result `outcome: "needs_route"`; any other step
  that asks to fails). `act` parks when the herdr tab it was routed to has vanished. The answer is the same `POST /route`, which routes it back
  to `act`.
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

- **Retries (built):** a transient failure is retried in-process twice, after 2 s and then 8 s (three tries in all; the delays go
  through an injected `Sleep`, so tests never wait), before the step goes `failed`. Adapters mark a transient failure with a
  `TransientError` (`ports/transient.ts`, the one place that classifies: an HTTP 5xx, a timeout or abort, a connection error such as
  ECONNREFUSED / ECONNRESET / `fetch failed`); the runner decides. Everything else (4xx, validation, an off-schema answer, an explicit
  throw) fails at once. A `TransientError` is `before_send` when the request provably never reached the destination (connection
  refused, DNS) and `after_send` otherwise (a timeout, a reset, a 5xx, an unrecognised `fetch failed`: it may have been delivered).

  **A hang guard is not transient.** The 30-minute guard of a model call (the agw job runner behind decide and triage) and the
  idle watchdogs (Hermes: no response, or a stream gone idle, within the idle window) mean the downstream is wedged, so a retry would only
  wait out the same window again (~90 minutes for three tries). They throw a plain error (`hangGuardFailure` in `ports/transient.ts`): the step fails after one window and `POST /retry` is the decision. A short request
  timeout that means "try again" (the 15 s agw request, the 30 s Hermes session create) stays transient, as do 5xx and connection errors. The STT and speech timeouts of the audio-gateway adapters have not been moved over yet and still count as transient.

  | Step | Retried on |
  |-|-|
  | transcribe, route (decide), summarize, notify | every transient failure |
  | act | `before_send` only: Hermes may already have run the turn after a timeout or 5xx, so those fail and `POST /retry` is the (human) decision |

  The agent-gateway job submit (`summarize`, `route` decide) is the exception inside those steps: a timeout, reset or 5xx on the submit
  may have created a paid job, so only a submit that provably never left (refused, DNS) is transient; any other submit failure is a plain
  error and fails the step. Failures while polling an accepted job are handled as before (three polls in a row cancel the job and fail
  the step). `stop()` (shutdown) during a backoff cuts the wait short and runs nothing more: the step stays `running`, not `failed`,
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
| `memos` | `seq` (autoincrement), `id` (uuid, client-minted), `mode` (auto/journal/hermes/tab/chat), `device` (authenticated device name), `state`, `failed_step`, `error`, `started_at`, `segment_count`, `audio_seconds`, `transcript`, `route`, `destination_ref`, `reply_text`, `summary_json`, `thread_id` (the Hermes session the memo belongs to: set by `act`, or at creation for a memo that continues a thread; NULL before then), `done` (0/1), `favorite` (0/1), `archived_at` (nullable ISO), `deleted_at` (nullable ISO; the soft delete), `created_at`, `updated_at` |
| `segments` | `memo_id`, `idx`, `bytes`, `sha256`, `received_at`: PK (`memo_id`, `idx`) |
| `memo_steps` | `memo_id`, `step`, `status`, `started_at`, `finished_at`, `error`, `usage_json`, `cost_usd`, `attempts` (INTEGER NOT NULL DEFAULT 1: tries used, see Retries; on the wire as `attempts` ≥ 1): PK (`memo_id`, `step`); `POST /retry` deletes the rows from the step on, so the re-run counts from 1 |
| `devices` | `device` (PK, the token-map name), `name` (display label), `platform` (ios/macos), `apns_token`, `apns_env` (sandbox/production), `push_to_start_token`, `last_seen_at`, `updated_at` |
| `activity_tokens` | `memo_id` (PK, cascades), `token`, `updated_at` |
| `threads` | `id` (PK, the Hermes session id), `kind` (chat/hermes), `title` (the first ~60 characters of the first transcript, whitespace collapsed), `created_at`, `updated_at`, `last_memo_id`. The destination names the thread in its `Delivery` (`thread: {id, kind, title}`; Hermes: the session id, `chat` or `hermes`, the first ~60 characters of the transcript); `act` persists what it gets, upserting the row and setting `memos.thread_id` in the transaction of `completeStep` (`patch.thread`; `thread_id` is an `act`-owned column). An existing thread keeps its kind and title and moves `updated_at` / `last_memo_id`. A retry from `act` clears `thread_id` when it is the memo's own session (equal to the memo id) until the re-run sets it again, and keeps it for a memo created to continue a thread (its `thread_id` is never its own id: `continuedThread` in `memo.ts`); the thread row stays. The migration backfilled one `hermes` thread per distinct `destination_ref` of an existing hermes memo. `GET /v1/threads` and `/v1/threads/:id` read it (§HTTP API); the queries sit behind the `ThreadStore` port (`adapters/sqlite-threads.ts`, composed into the memo store) |
| `memo_fts` | FTS5 virtual table, external content over the view `memo_search` (`seq`, `transcript`, headline = `summary_json.$.headline`; a malformed `summary_json` indexes as no headline), `content_rowid = seq`, tokenizer `unicode61 remove_diacritics 2`. Triggers on `memos` (insert, delete, update of `transcript` / `summary_json`) keep it in step; migration 7 backfills with `rebuild`. Read by `GET /v1/memos?q` only |
| `route_decisions` | `id` (autoincrement), `memo_id` (cascades), `created_at`, `source` (mode/prefix/decide/default/answer/correction), `destination` (nullable), `tab`, `confidence`, `model`, `cost_usd`, `reason`, `outcome` (routed/needs_route). One row per route outcome, written in the transaction of the step's `completeStep`; read with `listRouteDecisions(memoId)`. `answer` (written with the `needs_route` → `routed` move, `memos.route` set in the same transaction) and `correction` (logged after `act`, the memo is untouched) rows come from `POST /v1/memos/:id/route` |

**Indexes.** Besides the keys, `memos(state)`, `memos(thread_id)`, a partial `memos(deleted_at)`, `route_decisions(memo_id, id)`, and (one migration, for the stats reads' `>=` filters) `memos(created_at)` and `memo_steps(started_at)`.

**Memo flags and soft delete (Wave 13).** One append-only migration (the last entry) adds `done`, `favorite` (`INTEGER NOT NULL DEFAULT 0`), `archived_at`
and `deleted_at` (nullable ISO text, like the other time columns) and a partial index on `deleted_at`. None of them touches the state machine or the runner:
a flag is a user annotation, `updated_at` moves with it. `archived_at` is stamped once (archiving an archived memo keeps the first time). A delete is a
**soft delete**: `DELETE` stamps `deleted_at`, the memo stays readable through `GET /memos/:id` (`/audio` and `/speech` are 409 `bad_state` like the other live-only routes) and `POST /restore` clears it, until
`purge_at = deleted_at + PURGE_AFTER_MS` (10 minutes, `memo/memo.ts`, the one definition). The **purger** (`memo/purge.ts`, built from the store, the
audio store, the speech cache and the injected `Clock`) sweeps on boot and every 60 s (`PURGE_SWEEP_MS`): for each memo with `deleted_at <= now -
PURGE_AFTER_MS` it removes the audio files (segments and the combined recording, `AudioStore.remove`) and the speech files (`SpeechCache.remove`) first,
then the rows (`MemoStore.purge`: `memos`, which cascades `memo_steps`, `segments`, `route_decisions` and `activity_tokens`; the FTS triggers drop the index
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
| `POST /v1/memos/:id/retry` | `{from: Step}`, only for a `failed` memo |
| `POST /v1/memos/:id/route` | `{destination: hermes\|journal\|herdr, tab?}` (`tab` iff herdr). `needs_route`: the destination must be registered (else 400 "<dest> not available"); writes an `answer` decision, moves the memo to `routed` (compare-and-set) and drives it on: 202 + memo. After `act` (`acted`/`summarized`/`notified`): records a `correction` decision, no re-act, memo unchanged: 200. Any other state 409 `bad_state`, so a second answer while the first drives is a 409 |
| `GET /v1/memos?limit&cursor&q&route&state&favorite&archived&kind` | History, paged, newest first: `{items, pinned, pinnedTruncated, nextCursor}`. `q` (≤ 200 characters) searches transcript and summary headline (see Data model); `route` (hermes\|journal\|herdr) and `state` (any memo state) filter exactly; `favorite=true` keeps the favorites, `archived=true` lists **only** archived memos (without it archived memos are hidden), `kind=chat\|hermes` keeps the memos whose thread has that kind (the Chats chip); `favorite` and `archived` accept only `true` (omit them to switch off); all combine, an unknown value is 400. Soft-deleted memos are never listed or pinned. `items` never holds an **open** `needs_route` memo (one with `done` false), so the seq cursor stays stable when one leaves that state; the first page (no `cursor`) instead carries `pinned`: every open `needs_route` memo matching the filters, newest first, at most 50. `pinned` is always present, `[]` on later pages. `pinnedTruncated` is always present too: `true` on the first page when more than 50 open `needs_route` memos match (the oldest are left out of `pinned`), `false` otherwise and on every later page. `state=needs_route` answers from `pinned` plus, paged in `items`, the `done` ones. A `done` `needs_route` memo is no longer an open question: it is not pinned and sits in `items` at its seq position (the client dims it); marking one done after page 1 is the same case as answering it, so the de-duplication rule below covers it. `pinned` is not paged: the 50 cap is deliberate (a parked memo is an open question for the user, not an archive), `pinnedTruncated` is how a client learns the cap bit, and a `cursor` always yields `pinned: []`. Clients that read only `items` no longer see parked memos in the default list. A memo answered after page 1 leaves `needs_route` and appears in `items` at its seq position, so a later page can repeat a memo already in `pinned`: clients de-duplicate by memo id across `pinned` and every page (pinned first, then items whose id is not present yet) |
| `GET /v1/memos/:id` | Memo + step timeline. Also a soft-deleted memo (with `deletedAt` / `purgeAt`, so undo works); 404 after the purge |
| `PATCH /v1/memos/:id` | `{done?, favorite?, archived?}`: booleans, at least one; an empty body, an unknown key or a non-boolean is 400 (the route rejects unknown keys itself, Elysia strips them before validation). 200 memo; 404 unknown; 409 `bad_state` on a soft-deleted memo. Allowed in every pipeline state. Publishes `memo.updated` |
| `DELETE /v1/memos/:id` | Soft delete: 200 memo with `deletedAt` and `purgeAt`. Only settled memos (`notified`, `failed`, `needs_route`), else 409 `bad_state`. A repeat is idempotent (200, the first `deletedAt`, no event); 404 unknown. `retry` and `route` on a deleted memo are 409 `bad_state`. Publishes `memo.updated` |
| `POST /v1/memos/:id/restore` | Undo: 200 memo (`deletedAt` cleared, flags kept); 409 `bad_state` when the memo is not deleted; 404 once it is purged or past `purgeAt`. Publishes `memo.updated` |
| `GET /v1/memos/:id/result?wait=<s>` | Long-poll until result-ready (≤ 600 s) |
| `GET /v1/threads?kind=chat\|hermes&limit&cursor` | `{items: Thread[], nextCursor}`, newest `updatedAt` first; `Thread = {id, kind, title, createdAt, updatedAt, lastMemoId}`. The cursor is the last row's `(updated_at, id)`, so it stays valid as threads are added or updated. A malformed cursor or unknown `kind` is 400 |
| `GET /v1/threads/:id` | `{thread, memos, messages}`: the memos that ran in the thread (oldest first) and the conversation built from them, `messages: [{memoId, role: user\|assistant, content (markdown), createdAt}]`: per memo its `transcript` (`user`, dated by the memo's `createdAt`) and its `reply_text` (`assistant`, dated by the end of its `act` step; omitted while empty). Iris's own record: Hermes is not consulted, so the response never depends on it. Read in a fixed number of queries (the thread, its memos, the `act` finish times), however long the thread is. Unknown thread 404 |
| `GET /v1/memos/:id/audio` | The concatenated audio for the scrubber (`Range`); 409 `bad_state` for a soft-deleted memo |
| `GET /v1/memos/:id/speech` | TTS of the speech-ready variant of the answer (below), cached as an mp3; 409 `bad_state` for a soft-deleted memo |
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

**Threads.** A thread is a Hermes session (`threads` row, `kind` `chat` for a chat, else `hermes`). `threadId` on either create route continues one: the service answers 404 for an unknown thread, 409 `destination_unavailable` while Hermes is not registered (the turn could only fail at route, so create refuses it and stores nothing; a replay of an existing memo is judged by its stored thread instead) and 409 `conflict` for a replay whose `threadId` differs (`continuedThread`: a memo's own session, equal to its id, is not a continuation). The memo is stored with that `thread_id`. The route step forces it to `hermes` (decision source `mode`, no decider call, whatever the mode or a spoken prefix says; Hermes is registered by then, create refused the turn otherwise), and `act` delivers into the thread's session (`Destination.deliver({threadId})`: the Hermes adapter skips the session create), one turn at a time per thread (a keyed queue in the `act` handler: a second memo for the same thread waits for the first turn's reply instead of failing; different threads do not wait for each other. The wait is bounded at 30 minutes, the size of a hang guard, since a turn has an idle watchdog but no wall-clock cap: past it `act` fails with `KeyedQueueTimeout` (`thread <id> is busy: waited 1800000 ms behind memo <id>, which has not finished`) and the task never runs, `POST /retry` queues it again. The line stays consistent: the failed waiter keeps its place until the stuck turn ends, so a later memo still waits for that turn, and the stuck turn's eventual completion changes nothing for anyone. A turn that has started is never cut off. `memo/keyed-queue.ts` takes `maxWaitMs` and an injected cancellable sleep (the timer is cleared as soon as the turn ahead finishes, so a served waiter leaves nothing pending); herdr's per-pane queue leaves it off, its calls are bounded by their own 5 s timeouts) with `chat` taken from the thread's kind, not the memo's mode, so every turn of a chat thread re-sends the no-side-effects `system_message`. The upsert moves the thread's `updated_at` and `last_memo_id` as for any `act`. The conversation is Iris's own data (`threadMessages` in `memo.ts`, built from the thread's memos in `seq` order); Hermes keeps its session but its transcript is never read, and a chat is tagged by `threads.kind`, not by Hermes's `source`.

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
2. **transcribe:** `POST <audio-gateway>/v1/audio/transcriptions`.
   - Fields: `model=voxtral-mini-transcribe-3-0`, `language` (the device hint or
     auto), and `context_bias` (repo names, live tab labels, recent thread
     titles).
   - Header: `x-audio-source: iris`.
   - The gateway handles chunking up to about 2 h. A 413 is terminal.
3. **route:** only destinations with a registered act adapter are choices (`Destinations`).
   - If the memo's mode is not auto, it wins (`journal` → journal, `hermes` → hermes, `tab` → herdr, `chat` → hermes). Source `mode`; a chat memo is never routed elsewhere by prefix or `decide`. Mode `tab` carries no name:
     it routes to the only live tab, and parks with "which tab?" when there are several or none.
   - Otherwise the prefix parser matches "journal|tagebuch", "an hermes|hermes", "tab <name>", case- and diacritic-insensitive, with the
     phrase starting within the first 6 words. Everything up to and including the phrase, plus trailing punctuation, is
     cut from the text `act` and `summarize` receive (`deliveredTranscript`, derived from the raw transcript whenever a `prefix` decision exists;
     kept whole when nothing else was said). `memos.transcript` stays the raw speech-to-text, so a retry from `route` routes the same way. Source `prefix`; the spoken name is a single word, so a tab whose label contains a space cannot be addressed by voice (known limit; it can still be chosen by the decide path or an answer).
   - **Spoken tab resolution:** a spoken tab name is resolved against the live `Herd` to a tab id, which is what the decision stores. It matches
     a tab label or a workspace (repo) label, ignoring case and diacritics. Exactly one match routes; none or several park with a
     reason that names the spoken name (`no tab named "x"`, `several tabs match "x"`); a herd that cannot be read parks as "herd unavailable".
     Every park of this kind carries `destination: herdr`.
   - A mode or prefix that names an unregistered destination parks at `needs_route` with the reason "<destination> not available".
   - With fewer than two registered destinations the step stops here: it routes to the only one (source `default`, confidence 1, no spend). When that
     one is herdr it needs a tab like mode `tab` does: the only live tab, else a park with "which tab?" (or "herd unavailable").
   - Otherwise call `decide` through the `Decider` port (agw `decide` job, hang guard like `triage`) with state = transcript (first 4k chars) + one line
     per live tab, and questions `destination: choice[<registered>]`, plus `tab: choice[...]` when herdr is registered and there are live
     tabs. A failing `Herd` call omits the tab lines and the question. Source `decide`.
   - At confidence ≥ 0.8 → `routed` (for herdr the weaker of destination and tab confidence, and a live tab is required); otherwise
     `needs_route` with the model's best guess recorded as the decision's destination. A refusal, an unknown choice, herdr without a live tab
     and a missing decider ("decide unavailable") park the same way. An infrastructure failure of the call (transport error, hang guard,
     off-schema answer) throws instead: the step fails and `POST /retry {from: route}` recovers it.
   - Every outcome is written to `route_decisions`; the step row records the `decide` cost and usage. Span attributes `route`,
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
5. **summarize:** agw `triage` with the schema
   `{headline (≤60), detail (≤240), spoken (≤2 sentences)}` over the
   destination, transcript excerpt and reply. Journal and herdr skip the model
   and use templates (no spend, no summarizer needed): headline "Saved to journal" / "Sent to <repo> / <label>" (≤60; "Sent to tab" when the
   herd no longer lists the tab), detail the whitespace-collapsed transcript excerpt (≤240), spoken one sentence. Hermes keeps the model and
   fails the step without a summarizer.
6. **notify:**
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
  `summary.spoken` + "Details on screen." (the first whole sentences of the cleaned reply when there is no summary). Measured on the cleaned
  text, so a long code block does not push a short answer past it. Without a reply the (cleaned) `summary.spoken` is spoken.

### Downstream facts (re-verify when touching an adapter)

| Downstream | Contract | Where it is documented |
|-|-|-|
| audio-gateway | Synchronous multipart; `{text}` (`verbose_json` = one segment, so no timestamps); TTS at `POST /v1/audio/speech`, `response_format` mp3 | `audio-gateway/README.md` |
| agent-gateway | `POST :7705/api/jobs {tool, params}` → id; `GET /api/jobs/:id`; loopback, no auth; results carry `usage`, `model`, `latencyMs` | `agent-gateway/server/routes/jobs.ts`, AGENTS.md |
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
| `AUDIO_GATEWAY_URL` | audio-gateway base URL |
| `AGW_URL` | agent-gateway base URL |
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

### Capture engine (`IrisCapture`)

- **`AudioSessionController`:**
  - `.playAndRecord`, mode `.default`, options `.allowBluetoothHFP`,
    `.allowBluetoothA2DP` and `.bluetoothHighQualityRecording` (falls back to
    HFP; not available in the EU);
  - `setPrefersNoInterruptionsFromSystemAlerts(true)`;
  - interruptions handled through the iOS 26 notifications (`didBecomeInactive`,
    `resumptionRecommendation`). The take pauses (a segment boundary) and
    resumes.
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
  - each closed file goes to the `Outbox`;
  - a level meter is fed from tap RMS;
  - an engine configuration change restarts the engine and starts a new
    segment.
- **`Outbox`:**
  - a persistent queue in the App Group container, one entry per
    (memo, segment);
  - during the take it uploads over a default `URLSession` (the app is alive
    through background audio);
  - after [Stop], the remainder plus `complete` go through a background
    `URLSession`, followed by the `result?wait=600` long-poll as a background
    download, a backstop to APNs;
  - retries survive relaunches.
- **Memo ids** are minted at start: a UUID v4, which also serves as the trace
  id.

### Start paths

- **The intent:** `StartMemoIntent: AudioRecordingIntent` (+ `LiveActivityIntent`
  semantics) starts the engine and `Activity<MemoAttributes>.request(...)` in
  `perform()`. Apple requires the Live Activity, or the recording stops.
- **Callers:** the `ControlWidget` button calls the intent. So do Siri ("Record
  with Iris") and Control Center.
- **Fallback, accepted by the PRD:** if the system refuses to start a Live
  Activity from the background ("Target is not foreground", reported once), the
  control uses `openAppWhenRun` and the app auto-starts. Spike S1 decides.
- **`StopMemoIntent`, `SwitchInputIntent`, `PlayReplyIntent`:**
  `LiveActivityIntent`s used by the Live Activity buttons. `PlayReplyIntent`
  activates the session and plays `/speech`. Verify that playback starts from
  the background (S3); otherwise it opens the app.

### Live Activity (`MemoAttributes`)

- **Static:** `memoId`, `mode`, `startedAt`.
- **`ContentState`** (well under the 4 KB limit):
  - `phase` (recording/paused/uploading/processing/needsRoute/done/failed);
  - `inputName`;
  - `routeChip`;
  - `headline` (≤ 60 chars; the Lock Screen truncates around 160 pt);
  - `hasReply`.
- **Timer:** `Text(timerInterval:)` with `numericText` transitions.
- **Lifetime:** 8 h, plus 4 h on the Lock Screen, which is plenty for a 2 h
  take.
- **Updates:** local while the app runs; remote via APNs after suspension (the
  push token is registered per memo).

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
| History | Memo rows (route chip · state · headline · relative time), search, pull to refresh, SSE live updates |
| Memo detail | Transcript, audio scrubber, step timeline (durations, errors), route decision with confidence, cost, [Retry from…], [Play] |
| Thread | The Hermes transcript rendered with Textual, with hold-to-talk to append to this thread |
| Record | Full-screen take: timer, level waveform, mic picker (`AVInputPickerInteraction` + own list), mode/tab picker, [Stop] |
| Settings | Route mic rules, default mode, spoken replies, server URL + device token (Keychain), diagnostics (outbox, last errors, trace id copy) |

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
| `IrisUI` | IrisCore | swift-snapshot-testing (1.19.x, Swift Testing traits) for components and Live Activity views, pinned to one simulator runtime |
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
- **Propagation:** audio-gateway and agw don't accept `traceparent` (factory
  ADR-006 plans it), so Iris spans carry the memo id as an attribute on every
  downstream call. Once ADR-006 lands, `traceparent` is added.
- **Cost:**
  - STT/TTS spend is recorded by audio-gateway (`raw.caller=iris` via
    `x-audio-source`);
  - `decide`/`triage` spend goes into agw's NDJSON feed for usage-tracker, attributed to
    `caller: "iris"` (top level of the job body, set by the agw adapters);
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
| App flows | XCUITest smoke: launch → history → detail; Record screen with a fake recorder (`-IrisFakeCapture`) | mini, CI | `make uitest` |
| Agent verification | `xcodebuild` build/test, `xcrun simctl` (boot + `bootstatus -b`, install, launch, `io screenshot`, `openurl`, `push` for simulated notifications), and the `mobilebuildmcp` CLI (`ui-automation snapshot-ui` / `tap` / `type-text` / `screenshot`) | mini | `@verifier` / the `ios-verify` skill |
| Physical device | `devicectl device install app`; screenshots via `pymobiledevice3 developer core-device screen-capture screenshot` (devicectl has no screenshot verb) | mini → iPhone on LAN | `device` skill |
| Hardware-only | A checklist in `docs/spikes/device-checklist.md`: Lock Screen control, a 30-min background take, a mic switch iPhone↔AirPods↔car, a phone-call interruption, APNs Live Activity update | my hands | before each R-release |

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
  audio-gateway (STT/TTS) and the agw models. APNs payloads carry headlines
  only, never full transcripts.

## 13. Risks and unverified

| Risk | Plan |
|-|-|
| A Live Activity start from a control intent may need the foreground (one forum report) | S1; the fallback is `openAppWhenRun` + auto-start, accepted by the PRD |
| Built-in mic while connected to the car's Bluetooth is undocumented | S2 on hardware |
| TTS playback from a Live Activity intent while the app is suspended | S3; fall back to opening the app |
| Bun `node:http2` over-dispatch to APNs | Cap in-flight streams (D6); Bun 1.3.14's HTTP/2 `fetch` as a fallback |
| `xcode-27` is a preview CI image | Fall back to `macos-26` (D14) |
| Exact Swift build-setting spellings (default isolation) | Verified in the setup wave against Xcode 27.1 |
| `decide` confidence calibration | Logged decisions and corrections; threshold tuned after 100 memos |
| Voxtral has no timestamps | Plain transcript in R1–R3; revisit if a synced transcript matters |
