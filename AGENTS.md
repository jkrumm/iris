# iris — Agent Instructions

Voice channel into the agent platform. A memo recorded on a phone is uploaded as 10 s segments, transcribed, routed to Hermes,
summarized and notified. A public monorepo: `server/` (Bun + Elysia + `bun:sqlite`, runs on the mini), `apple/` (iOS app, Mac app, packages),
`contracts/` (the wire contract both sides test against). **`docs/TDD.md` is the design, `docs/PRD.md` is the product, `docs/waves/PLAN.md` is
the implementation chain** (foundation waves, then the fleet backlog). Read the TDD section named by a rule before changing that area.

## Layout

| Path | Holds |
|-|-|
| `server/` | iris-server: memo domain, HTTP, adapters, telemetry (detail below) |
| `contracts/` | `schema/*.json` (generated), `fixtures/*.json` (hand-written, Swift decodes every one), `manifest.json` (every route) |
| `apple/project.yml` | XcodeGen spec: `Iris`, `IrisWidgets`, `IrisNotifications`, `IrisMac`, `IrisUITests`; `Iris.xcodeproj` is generated and gitignored |
| `apple/Packages/` | `IrisCore` (models, API client, SSE), `IrisCapture` (session, rotation, outbox), `IrisUI` (Theme from basalt-ui, components), `IrisTelemetry` |
| `apple/{Iris,IrisWidgets,IrisNotifications,IrisMac}` | thin app targets; `apple/Tests/UITests` XCUITest smoke; `apple/tools/` Theme generator (Bun) |
| `scripts/` | `send-memo.ts` (driver), `e2e.ts`, `smoke.sh`, `launch.sh`, `mini-deploy.sh`, `public-guard.ts`, `mbm` (mobilebuildmcp CLI wrapper) |
| `launchd/` | LaunchAgent plist templates for the mini |
| `fixtures/audio/` | the German smoke recording and how it was made |
| `.claude/rules/`, `.claude/skills/` | rules and skills, indexed below |
| `docs/` | `PRD.md`, `TDD.md`, `research/`, `spikes/` (S1-S3 briefs, device checklist), `waves/PLAN.md` |

## Rules and skills

| Rule (lazy, by path) | Covers |
|-|-|
| `.claude/rules/swift.md` | generic Swift: Swift 6 mode, `@Observable`, Swift Testing, `os.Logger` |
| `.claude/rules/apple.md` (`apple/**`) | Iris invariants: no `AVAudioRecorder`, segment rotation + outbox, Live Activity limits, fixtures as truth |
| `.claude/rules/server.md` (`server/**`) | ports and adapters, the pure state machine, contracts, idempotency, telemetry |

| Skill | Use when |
|-|-|
| `iris-server` | changing the server, an adapter, a step, or the API contract |
| `ios-verify` | proving an Apple change: build, run, screenshot, UI tree, tap, snapshots, UI test |
| `apple-dev` | any `xcodebuild` / `simctl` / `xcodegen` / signing question on the mini |
| `device` | the paired iPhone: install, launch, screenshot, the hardware checklist |
| `memo-debug` | one memo: timeline, HyperDX trace, retry |
| `apple-capture-notes` | before touching capture, intents or the Live Activity (verified and unverified iOS facts) |
| `swiftui-pro`, `swift-concurrency-pro`, `swift-testing-pro`, `swiftdata-pro` | vendored MIT skills (pins: `.claude/skills/VENDORED.md`) |

## Tooling setup (mini)

Xcode 27.1 via `xcodes` (`~/.local/bin/xcodes`, installed by `dotfiles/scripts/install-xcodes.sh`), XcodeGen, `pymobiledevice3` (uv tool);
all from dotfiles (`make _setup-tools`). No MCP servers anywhere (TDD D17): UI automation is `scripts/mbm` (a pinned `mobilebuildmcp` CLI via
`npx`, Sentry off), Apple's own CLIs do the rest. Pinned simulator: iPhone 17, iOS 27.0 (`SIM_NAME` / `SIM_OS`, Makefile). Agent verification
targets: `make sim`, `make run-sim`, `make screenshot`, `make ui-snapshot` (artifacts in `.artifacts/`, gitignored); recipes in `ios-verify`.
Without Xcode (Linux, CI `check` job) the Apple targets are skipped; the `apple.yml` run on the hosted `xcode-27` image is the Apple gate.
Never start dev servers for a human to look at; simulators are fine, shut them down after.

## Server (`server/`)

- `server/src/app.ts` — `createApp({deviceTokens, memos, stats?, degraded?, sseKeepaliveMs?})`: mounts routes, no env/fs.
- `server/src/index.ts` — entry point: SQLite, audio-fs, runner, service, then `compose()` for the downstream ports,
  listen, background `driveAll`, signals, DB close, OTel flush.
- `server/src/memo/` — domain: `memo.ts` (states, steps, transitions), `store.ts` (port), `runner.ts`
  (idempotent step runner, concurrency-bounded `driveAll`, `idle()`), `service.ts` (`MemoService`, what HTTP calls), `media.ts`
  (`MemoMedia`: the combined recording and the spoken result, both disk-cached and single-flight), `speech-text.ts` (`speechVariant`: the markdown-free, length-capped text `/speech` synthesizes, TDD §3), `events.ts` (in-process
  pub/sub), `purge.ts` (the purger: removes soft-deleted memos' files and rows after the 10-minute undo window), `errors.ts` (`MemoError` codes, `configured()` for optional subsystems), `test-support.ts` (fake audio, seeded and parked memos).
- `server/src/pipeline/steps.ts` — `createStepHandlers`: the five step handlers, each a pure function
  of (memo, ports); a handler is registered only when its port is provided (`route` and `act` need at least one registered destination;
  `act` dispatches on `memo.route`).
- `server/src/routing/` — `prefix.ts` (`parsePrefix`, pure), `route.ts` (`route`: mode → prefix → only destination → `Decider`, always
  returns a `RouteDecision`, never throws; a spoken or mode `tab` is resolved against the herd to a tab id), `index.ts`.
- `server/src/adapters/` — `sqlite.ts` (+ `sqlite-migrations.ts`, `PRAGMA user_version`; migration 7 adds the `memo_fts` FTS5 index behind history search), `sqlite-devices.ts`
  (`DeviceStore`, same db), `sqlite-threads.ts` (`ThreadStore`: the thread read queries, composed into the memo store), `sqlite-stats.ts` (`StatsStore`: read-only aggregates behind `GET /stats`), `audio-fs.ts` (segments + `combined.m4a`), `speech-fs.ts` (`<id>.mp3` + `<id>.txt`), `assets-fs.ts` (`<id>/<asset id>` reply assets), `diagram-pele.ts` (`DiagramRenderer`: Pele + resvg-js; migration 11 adds `reply_assets`),
  and the downstream adapters (audio-gateway transcriber + ffmpeg combiner, `audio-gateway-speaker.ts`, Hermes, agw (`agw.ts`: `triage` summarizer
  and the shared job runner; `agw-decider.ts`: the `decide` job),
  `herdr.ts` over the unix socket: the `Herd` and the `herdr` `Destination`, log notifier), and the APNs pair: `notifier-apns.ts` (`Notifier` over an `ApnsTransport`)
  and `apns-node.ts` (the transport on `@parse/node-apn`; `apns-test-support.ts` generates test keys and certs).
- `server/src/ports/` — `audio.ts` (`AudioStore`, `AudioCombiner`, `Recording`), `clock.ts` (system, fixed and manual clocks),
  `transcriber.ts`, `speaker.ts` (+ `SpeechCache`), `devices.ts` (`DeviceStore`: devices, APNs tokens, Live Activity tokens), `diagram.ts` (`DiagramRenderer`), `assets.ts` (`AssetStore`),
  `stats.ts` (`StatsStore`), `herd.ts`, `destination.ts` (+ `Destinations`, the registry of act adapters), `decider.ts`, `summarizer.ts`, `notifier.ts` (`notify` + best-effort `phase`),
  `apns.ts` (`ApnsTransport`), `fakes.ts` (in-memory fakes of the ports, incl. `fakeApnsTransport`).
- `server/src/notify/` — `payloads.ts` (pure alert / Live Activity builders), `phases.ts` (`bindPhaseUpdates`: memo events →
  `notifier.phase`), `needs-route.ts` (`bindNeedsRouteAlerts`: entering `needs_route` → `notifier.needsRoute`), `select.ts` (`selectNotifier`: APNs or log, plus the transport's `close`),
  `lifecycle.ts` (`createNotifyLifecycle`: stop / idle / close for shutdown).
- `server/src/http/` — `auth.ts` (device-token guard), `memos.ts`, `devices.ts`, `media.ts` (audio + speech, `Range`; reply assets),
  `threads.ts` (`/threads`), `herd.ts`, `stats.ts`, `events.ts` and `telemetry.ts` (route plugins; `telemetry.ts` reads and validates its own body), `schemas.ts` (every request/response shape as pure TypeBox, exported for the
  contracts), `errors.ts` (the one `MemoError` → status mapping), `serialize.ts` (the one wire-shape mapping, camelCase),
  `test-support.ts` (in-memory app for `app.handle` tests).
- `server/src/telemetry/` — `otel.ts`, `otel-format.ts`, `log.ts`, copied from research-gateway
  (hand-rolled OTLP JSON, no SDK). The trace id is the memo UUID with dashes stripped. Added here: `exportOtlp` in `otel.ts`
  (posts a payload built elsewhere), `relay.ts` (`createTelemetryRelay`: a client `TelemetryBatch` → OTLP traces and logs under the
  client's own resource, through the `OtlpExporter` port), `fakes.ts` (`fakeOtlpExporter`), `limits.ts` (256 KiB, 500 records).
- `server/src/env.ts` — the only place `process.env` is parsed.
- `server/src/contracts/` — `registry.ts` (contract name → TypeBox schema), `export.ts` (TypeBox → JSON Schema),
  `manifest.ts` (zod shape of `contracts/manifest.json`), `routes.ts` (the real app's route table),
  `check.ts` (`checkContracts`), `cli.ts` (`export` | `check`), `conformance.test.ts` (live app vs contracts).
- `contracts/` — the wire contract Swift decodes: `schema/<name>.json` (generated, JSON Schema 2020-12),
  `fixtures/<name>[.<variant>].json` (hand-written, valid against schema `<name>`), `manifest.json` (every route
  with its schema names, status codes and media types; binary and SSE routes included).
- `server/src/compose.ts` — `compose({env, db, devices, clock, dataDir})`: builds the stats store over `db` and is the one place a downstream port is chosen (fake under
  `IRIS_FAKES=1`, real adapter when its env is set, else absent and named in `degraded`); also the notifier and the device tokens.
  A new port is one entry there, its fake in `fakePorts`, and its env var in `env.ts`.
- `scripts/` — `send-memo.ts` (driver), `e2e.ts` (`make e2e`), `smoke.sh`, `launch.sh` (LaunchAgent entry), `mini-deploy.sh` (poller tick);
  `launchd/` — plist templates; `fixtures/audio/` — the German smoke recording.


## HTTP API

All under `/v1`, `Authorization: Bearer <token>`. Errors: `{error: <code>, message}`.

| Route | Result |
|-|-|
| `POST /memos` `{id, mode: auto\|journal\|hermes\|tab\|chat, startedAt, threadId?}` | 201 memo; 200 if it exists for this device; 409 other device or another `threadId` on the replay; `threadId` continues that thread (delivered into its Hermes session, route forced to hermes), 404 when unknown |
| `POST /memos/text` `{id, mode, startedAt, text, threadId?}` | 202 memo created in `transcribed` (`transcript` = trimmed text, driven from `route`; a replay too); memo carries `typed: true`; any mode incl. `chat`; 400 empty, over 20 000 code points, or no/unknown `mode`; 409 another body (incl. `threadId`), device or a recorded memo with that id; 404 unknown `threadId` |
| `PUT /memos/:id/segments/:n` raw `audio/mp4` bytes | 200, idempotent by sha256 (same sha no-op, different sha 409); 413 over `IRIS_MAX_SEGMENT_BYTES`; 409 after `complete` |
| `POST /memos/:id/complete` `{segmentCount}` | 202 memo (repeat too); 422 `missing_segments` + `missing: [...]` |
| `POST /memos/:id/retry` `{from}` | 202 memo; 409 unless `failed` |
| `POST /memos/:id/route` `{destination: hermes\|journal\|herdr, tab?}` | `needs_route`: 202 memo, routed and driven on (400 `<dest> not available` when unregistered; `tab` iff herdr); after `act` (`acted`/`summarized`/`notified`): 200 memo, a `correction` is only logged; other states and a second answer 409; 404 unknown |
| `GET /memos?limit&cursor&q&route&state&favorite&archived&kind` | `{items, pinned, pinnedTruncated, nextCursor}`, newest first; `q` = FTS5 over transcript + headline (prefix, case/umlaut-insensitive), `route` / `state` exact, `favorite=true`, `archived=true` (only archived; hidden otherwise), `kind=chat\|hermes` (thread kind) (unknown 400); soft-deleted memos never listed; open `needs_route` memos (not `done`) are never in `items`, the first page pins them in `pinned` (≤ 50; `pinnedTruncated` true when more matched, false on later pages), later pages `[]`; a `done` one is paged in `items` |
| `GET /memos/:id` | memo + `steps` timeline + `segmentCount`; 404 unknown. A soft-deleted memo is returned too (with `deletedAt` / `purgeAt`); 404 once purged |
| `PATCH /memos/:id` `{done?, favorite?, archived?}` | 200 memo; ≥ 1 boolean, an empty body, unknown key or non-boolean 400; 409 `bad_state` on a soft-deleted memo; 404 unknown; publishes `memo.updated` |
| `DELETE /memos/:id` | soft delete: 200 memo with `deletedAt` + `purgeAt` (10 min later); only `notified` / `failed` / `needs_route` / `receiving` (a cancelled take: its later segment and `complete` are 409 `bad_state`, no pipeline) else 409 `bad_state`; a repeat is idempotent; the purger then removes audio, speech and rows (`memo.purged`) |
| `POST /memos/:id/restore` | 200 memo, `deletedAt` cleared; 409 when not deleted; 404 once purged |
| `GET /memos/:id/result?wait=<s>` | 200 once result-ready, else 202 after the wait (0..600, default 0) |
| `GET /threads?kind=chat\|hermes&limit&cursor` | `{items: Thread[], nextCursor}`, newest `updatedAt` first; `Thread = {id, kind, title, createdAt, updatedAt, lastMemoId}` |
| `GET /threads/:id` | `{thread, memos (oldest first), messages: [{memoId, role: user\|assistant, content, createdAt}]}`: the conversation is built from the memos' transcripts and replies (Iris's own record, no Hermes read); 404 unknown |
| `POST /devices/register` `{name, platform: ios\|macos, apnsToken?, apnsEnv?, pushToStartToken?}` | 200 `{device, name, platform, apnsEnv, hasApnsToken, hasPushToStartToken, registeredAt}`; upsert by the authenticated device |
| `POST /telemetry` `{resource, spans, logs, dropped}` (the Swift `TelemetryBatch`) | 202 `{accepted: {spans, logs}}`; exported in the background as OTLP with `service.name=iris-ios\|iris-macos`, the memo trace id kept; 413 over 256 KiB, 400 over 500 spans+logs, a schema violation or a bad timestamp |
| `PUT /memos/:id/activity-token` `{token}` (hex) | 204, replaces the stored token; 404 unknown memo |
| `GET /memos/:id/audio` | `audio/mp4`, concatenated on first request and cached; `Range` → 206 / 416; 404; 409 while `receiving` or soft-deleted |
| `GET /memos/:id/assets/:assetId` | a rendered Mermaid file of the reply (ids in the memo's `replyBlocks`): `image/svg+xml` (CSP `default-src 'none'`) or `image/png`, immutable cache; 404 unknown memo or asset; 409 when soft-deleted |
| `GET /memos/:id/speech` | `audio/mpeg` TTS of the speech-ready variant (`speechVariant`: cleaned reply, or `summary.spoken` + "details on screen" past 600 chars; else `summary.spoken`), cached; 404; 409 with neither or when soft-deleted; 503 without audio-gateway |
| `GET /herd` | `{tabs: [{id, repo, label, agentState, lastActivity}]}` from herdr; 503 without `HERDR_SOCKET` or when herdr is unreachable |
| `GET /stats?days=<n>` | `{days, from, to, perDay, perWeek, stepMedians (per step and route, with n), costPerRoute}` over the last `n` local days (default 30, 1..365 else 400); read-only SQL/JS aggregates, `null` route = `unrouted` |
| `GET /events` | SSE: `ready`, `memo.updated` per state change (and per flag change, delete or restore, without `memo.done`), plus `memo.done` when result-ready, `: keepalive` every 15 s |

Codes: not_found 404, conflict / bad_state / destination_unavailable 409, missing_segments 422, too_large 413, bad_request 400, unavailable 503.
Wire JSON is camelCase.
States: `receiving → received → transcribed → routed | needs_route → acted → summarized → notified`,
with `failed(step)` as a side state.


## Validate

| Target | Runs | Where |
|-|-|-|
| `make check` | `check-server` (oxlint, `oxfmt --check`, `tsc --noEmit`, `bun test`), `check-contracts`, `guard`, and `check-apple` wherever `xcodebuild` exists | mini, CI (`check.yml`, no Apple on Linux) |
| `make e2e` | the pipeline against a fake-booted server (needs ffmpeg) | mini, CI after `check` |
| `make check-apple` | Theme drift, `swift format lint --strict`, `swift test` per package (macOS host), `xcodebuild build` of `Iris` + extensions (simulator) and `IrisMac` | mini, CI (`apple.yml`) |
| `make snapshots` | IrisUI snapshot tests on the pinned simulator (`RECORD=1` re-records) | mini, `apple.yml` |
| `make uitest` | XCUITest smoke (`-IrisFakeCapture`) | mini, `apple.yml` |
| `make guard` | public-repo scan (IPs, tailnet/real hostnames, token shapes) | mini, CI, lefthook pre-commit |
| `make verify` / `make smoke` | production health / a real recording through production | mini only, after deploy |

`make format` applies oxfmt. `make generate` builds `apple/Iris.xcodeproj`; `make theme` regenerates `IrisUI/Theme`. Toolchain recipes: `apple-dev`.
Fix errors in changed files only. A change to the API runs `make contracts` first (skill `iris-server`).

**Public repo:** no real hostnames, IPs, tailnet names, tokens or personal emails in any tracked file (`make guard` + the pre-commit hook enforce it;
the real-domain literals live in untracked `~/.config/iris/guard-extra.txt`). Use `<domain>`, `iris.mini.<domain>`, `example.com`; `op://` refs in
`.env*.tpl` are fine. The CI runs on hosted runners.

### Server and pipeline details

`make e2e` (`scripts/e2e.ts`, CI after `check`, needs ffmpeg) boots `server/src/index.ts` on a free port with
`IRIS_FAKES=1` and a temp `IRIS_DATA`, runs `send-memo.ts` on the smoke recording (must reach `notified`), then probes
`/devices/register`, `/activity-token`, `/audio` (Range 206), `/speech` (audio/mpeg), `/herd` and the threads flow (a chat memo, a reply into its thread
with `send-memo.ts --thread`, then `/threads` and `/threads/:id` with both turns). The server is always killed.

**`IRIS_FAKES=1`** (boolean-ish, empty = off) builds every port from `compose()`'s fakes, ignoring downstream env, and keeps the
real ffmpeg combiner. `/health` is `degraded` with `"fakes"`, boot logs `server.fakes_mode`, and `scripts/launch.sh`
refuses to start when `IRIS_FAKES` is set. Never set it in production.

`make check-contracts` — the exported JSON Schemas equal `contracts/schema` byte for byte, every fixture validates
(ajv 2020, strict), and `manifest.json` lists exactly the routes `createApp(...).routes` serves. `make contracts`
regenerates `contracts/schema`. It is part of `make check` and of CI.

Tests are colocated `*.test.ts`. Ports and adapters: dependencies are injected, tests use
in-memory SQLite and fake ports, no `mock.module` / `spyOn`, HTTP via `app.handle(new Request())`.

**Harness:** `bun scripts/send-memo.ts <audio-file>` is the end-to-end driver. It splits the file into
10 s m4a segments with ffmpeg, then creates, uploads, completes and long-polls a memo like the phone
does, and prints transcript, reply, summary, step timings and cost. Env: `IRIS_URL` (default
`http://127.0.0.1:7730`), `IRIS_TOKEN` (required); flags `--url --token --mode auto|journal|hermes|tab|chat
--wait <s>`. Exit 0 `notified`, 1 `failed`, 2 timeout, `needs_route` or usage error. Its tests
(`bun test scripts`, fake in-process server) run via the repo root; lint and format cover `scripts/`.

## Deploy

Push to master deploys. LaunchAgent `com.jkrumm.iris` (KeepAlive, `ExitTimeOut` 60 s) runs
`scripts/launch.sh` from the deploy clone `~/.iris/app`, never this checkout; data lives in
`~/.iris/data`; it listens on `127.0.0.1:7730`. Doors: `iris.test` (local) and
`iris.mini.<domain>` (tailnet), both Caddy in `dotfiles/config/Caddyfile`.

- `com.jkrumm.iris-deploy` polls `scripts/mini-deploy.sh` every 120 s through `jobrun`. It deploys
  `origin/master` only when the `check` job is green on that SHA and no memo is mid-step
  (`/health` `inflight` is 0). It restarts only for runtime paths (docs, tests, Makefile and
  `launchd/` do not; `launchd/` prints a warning), and writes `~/.iris/deployed-sha` once the new
  pid answers `/health`. `make deploy` runs one tick now.
- First install or a changed `launchd/` template: `make mini-setup` / `make launchd-install` on the mini.
- Secrets: `.env.local.tpl` + `.env.mini.tpl` (+ optional `.env.mini.otel.tpl`) via `secrets-run`.
  `launch.sh` refuses to start if a base ref does not resolve; a missing OTel overlay starts degraded.
  Device tokens, the audio-gateway URL and the OTLP endpoint live in `op://mini/iris/*` (listed in
  `dotfiles-private/headless.refs`). Rotate a token: edit the field, `make secrets-seed` from the
  MacBook, `make launchd-restart`. `APNS_*` is unset (no `op://` ref yet, so not in `.env.mini.tpl`; add both at enrolment), so the log notifier runs.
- `HERMES_URL` is composed in `launch.sh` from `HERMES_HOST` + `HERMES_PORT`. The journal takes brain-sync's mkdir lock exactly as `brain/brain-sync.sh` does (own pid in `<lockDir>/pid`; a live pid or a pidless lock under 60 s waits, a dead pid or an older pidless lock is reclaimed; release only while the pid is still ours). It pushes the brain checkout over HTTPS with the mini's headless credential helper (no prompt); `launch.sh` exports `BRAIN_DIR` only when the checkout exists.
- agent-gateway jobs (`triage`, `decide`) are submitted with `caller: "iris"` at the top level of the `POST /api/jobs` body, for per-consumer spend attribution; an older gateway ignores it.


## Verify & Monitor

- `make verify` — exit 0 iff `GET /health` answers `status: ok` (public; `{status, degraded[], inflight}`).
  `degraded` lists `otel`, `device-tokens` and steps without a downstream (`transcribe`, `act` (no destination at all), `summarize`, and `decide` when two or more destinations have no decider).
- `make smoke` — a real German 96 s recording (`fixtures/audio/de-90s.m4a`) through the pipeline to
  `notified`; it pins `--mode hermes`, because an `auto` memo could land in the real brain or a live tab. `IRIS_URL=https://iris.mini.<domain> make smoke` goes through the tailnet door. Uses the
  `smoke` device token; the memo shows up in a Hermes session named by the memo id.
- `make logs` (bounded tail of `~/Library/Logs/iris{.log,.err}` and `iris-deploy.log`),
  `make launchd-status`, `make launchd-restart` (refuses while `inflight > 0`, `FORCE=1` overrides).
- Traces and logs: HyperDX, `service.name=iris-server`, trace id = memo UUID without dashes. Root span
  `memo`, a child per step. Query via `/otel` (prod).


## Gotchas

- **Contracts:** change a route or schema → `make contracts`, update the fixtures (every variant a client must
  decode), `make check-contracts`. A new route needs a `manifest.json` entry or the check fails. Fixtures are the
  Swift side's source of truth: realistic, camelCase, fixed ids and timestamps, no real hosts or tokens.
  `liveactivity.content-state` has no `inputName`: the device knows it and the Swift `ContentState` declares it
  optional. `routeChip` and `headline` are omitted, never null. Elysia mutates the shared TypeBox objects when it
  composes routes (adds `additionalProperties: false`), so `export.ts` strips that keyword to stay order-independent.
- **Telemetry relay** (`POST /v1/telemetry`, TDD §8): the route reads and validates its own body (`parse: "none"`, `TypeCompiler` over
  `TelemetryBatch`) so a bad token is 401 before any byte is read and an oversized body is cut off at 256 KiB (413 `too_large`).
  `compose()` always builds it (a `fakeOtlpExporter` under `IRIS_FAKES`, else `exportOtlp`, a no-op without `OTEL_EXPORTER_OTLP_ENDPOINT`).
  An export that fails, or is refused because `MAX_IN_FLIGHT` (4) posts are already outstanding (same bound as the batch flush, no fetch), is a `telemetry.relay_failed` log line, never an error to the client; the export is registered with `flushOtel`,
  so the shutdown flush waits for it. Resource: `service.name` (client), `service.version`, `device.name`, `deployment.environment`;
  `host.name=mini` is deliberately not on client records. No de-duplication of a resent batch.
- **Auth:** `/v1/*` requires `Authorization: Bearer <token>`; `IRIS_DEVICE_TOKENS` is
  `token=device,token=device`. Empty means every `/v1` call is 401. Real tokens live in
  1Password, never in the repo.
- **Elysia:** chain methods (types), and mount the guard with `as: "scoped"` so it reaches
  sibling plugins. See `dotfiles/rules/elysia.md`.
- **Public repo:** no real hostnames, IPs, tailnet names, tokens or personal emails in any tracked
  file. Use placeholders (`<domain>`, `iris.mini.<domain>`); `op://` refs in `.env.tpl` are fine.
- **Trust model:** every device token is trusted equally; memos, history and SSE are shared
  across devices on purpose (the Mac shows the phone's memos). Ownership is checked only on create.
- **Segments** are idempotent by sha256 (same bytes no-op, different bytes 409, the stored file is
  never overwritten) and rejected (409) after `complete`.
- **`needs_route`** is parked (the runner does not resume it) and counts as result-ready.
- **Step results live on the memo row** (`audio_seconds`, `transcript`, `route`, `destination_ref`,
  `reply_text`, `summary_json`), written by `MemoStore.completeStep` in one transaction with the state
  change and the done row; a lost compare-and-set writes nothing. `resetForRetry` clears the columns of
  the re-run steps and later. A store error in `completeStep` is bookkeeping, not a step failure: it
  propagates and the drive failure is logged.
- **Downstream env** (all optional, empty = unset): `AUDIO_GATEWAY_URL`, `AGW_URL`, `HERMES_URL` +
  `HERMES_TOKEN`, `HERDR_SOCKET` and `BRAIN_DIR` (`launch.sh` sets each on the mini only when it exists: the herdr socket, `~/SourceRoot/brain`; a herdr started after iris needs `make launchd-restart`). Each of
  `BRAIN_DIR` (journal), `HERDR_SOCKET` (herdr, also the herd) and `HERMES_*` registers its destination on its own; a missing one is not
  `degraded`, `act` is only when none is registered. Without the rest, `/health` lists `transcribe` /
  `summarize` / `act` / `speech` / `herd` in `degraded`; the first two park memos before that step (`summarize` always has a handler: journal and herdr use a template, a hermes memo fails the step without a summarizer), the last two
  answer 503 `unavailable`.
- **Chat mode and threads** (TDD §3 act, data model): mode `chat` routes to hermes (source `mode`, never prefix or `decide`); `act` passes `chat: true` to
  `Destination.deliver`, and the Hermes adapter then opens its session with `source: "iris-chat"` and sends a no-side-effects `system_message` on every turn
  (Hermes' per-turn ephemeral system prompt, not stored). Hermes maps unknown `source` values to `api_server`, so `threads.kind` (`chat|hermes`) is the
  marker, not Hermes. The Hermes adapter names the thread in its `Delivery.thread` (`{id, kind, title}`, id = session id = `destination_ref`); `act` persists it
  (`patch.thread`: `completeStep` upserts the `threads` row and sets the `act`-owned `memos.thread_id`). The memo wire carries `threadId`, omitted when null.
  Continuing a thread: `threadId` on either create route (404 unknown thread, 409 `destination_unavailable` while hermes is not registered, 409 on a replay naming another; `continuedThread` in `memo.ts` tells a continuation from a memo's own
  session, whose id is the memo id), the route step forces `hermes`, `deliver({threadId})` talks into the existing session and `chat` comes from the thread's kind. Turns into one thread run one at a time (`memo/keyed-queue.ts` in the `act` handler; the second waits, at most 30 min: then `act` fails "thread <id> is busy" naming the memo ahead and its task never runs, the line stays ordered; a waiter parked there releases its `driveAll` slot through the handler's `whileWaiting` and takes one again when its turn comes; herdr's per-pane queue holds at most 8 deliveries (`maxPaneQueue`), the ninth fails "herdr pane <id> queue is full", not transient). `/threads/:id`
  builds its conversation from the thread's memos (transcript = user, `reply_text` = assistant), never from Hermes. Swift: `MemoMode` decodes an unknown value to `.unknown`.
- **Routing** (`routing/`, TDD §3 step 3), in order: a mode other than `auto` wins (source `mode`); a spoken prefix within the first 6 words
  (`journal|tagebuch`, `an hermes|hermes`, `tab <name>`; case and diacritics folded; the name may be several words, the longest live tab or repo label wins) routes (`prefix`); `memo.transcript` stays the raw speech-to-text and `act` / `summarize` cut the prefix again via `deliveredTranscript` by the `prefix_words` count the decision row recorded;
  with fewer than two registered destinations the only one wins (`default`, confidence 1, no spend); two or more (production since Wave 11: journal, herdr, hermes; `IRIS_FAKES` registers all three) turn the decider on; otherwise `Decider` (agw `decide`, the job runner's hang guard): confidence ≥ 0.8 routes, else `needs_route`. A mode or prefix
  naming an unregistered destination (an unset `BRAIN_DIR`, `HERDR_SOCKET` or `HERMES_*`), a refusal, an unknown choice, herdr without a live tab, low confidence and a missing
  decider (`decide` in `/health` `degraded`, only with ≥ 2 destinations) park at `needs_route`. A decide infrastructure failure (transport error, hang-guard
  timeout, off-schema answer) throws; a hang guard is a plain error, never `TransientError` (`hangGuardFailure`, TDD §3 Retries), so the route step fails after one window and `POST /retry {from: route}` recovers it. With no destination at all neither `route`
  nor `act` is registered and the memo waits at `transcribed`. Every outcome is one `route_decisions` row written by `completeStep` with the step
  (`patch.routeDecision`); the park reason is the latest row's `reason` (`store.listRouteDecisions`), a low-confidence park keeps the model's guess
  in `destination`. Because the transcript is never rewritten, a retry from `route` routes by the same prefix again.
  A spoken tab name (`tab <name>`, one word) matches a tab label or a workspace label (case and diacritics folded) on the live herd and stores the
  tab id; none or several matches park naming the spoken name, an unreadable herd parks as "herd unavailable". Mode `tab` has no name: the only live tab, else
  "which tab?"; so does herdr as the only registered destination (source `default`). A multi-word tab name cannot be spoken (one-word limit of the prefix). `act` passes the routing decision's tab to `Destination.deliver({tab})`; a route with no tab, or a tab that has vanished by then (`TabGoneError`, also herdr's `pane_not_found` on a write), parks the memo
  at `needs_route` again (a decision row, reason "tab <id> is gone", the routing decision's source), `act` being the second step that may park.
  `summarize` for journal and herdr is a template (no model call, no summarizer needed).
- **Answering a park** (`POST /memos/:id/route`, `MemoService.route`): `store.answerRoute` is one transaction (`needs_route` → `routed` compare-and-set,
  `memos.route` set, an `answer` decision row), then `memo.updated` (`routed`, step `route`) is published and the runner drives on with `act`. A second answer
  while the first drives is 409 `bad_state` (the memo left `needs_route`), which is the idempotency story. After `act`, `store.recordCorrection` only appends a
  `correction` row (log `route.decided {source: "correction", corrected: true}`), no re-act, no event. `act` and `summarize` still cut a spoken prefix after an answer
  (`deliveredTranscript` looks for any `prefix` row), so a prefix park answered with another destination delivers the text without the prefix word. The
  destinations an answer may pick are the registered ones (`createMemoService({destinations})`, from `compose()`); `tab` is not checked against the herd.
  While `needs_route` the memo wire shape carries `routeReason` (latest decision's `reason`) and, for a low-confidence park, `routeSuggestion` (its `destination`);
  derived by the store's `SELECT`, omitted (never null) in every other state. Elysia's `t.UnionEnum` defaults a missing value to its first member, so `RouteBody.destination` and `RetryBody.from` set `default: undefined` (a missing field is a 400).
- **`act` is at-least-once:** a crash or restart mid-`act` replays the step, which posts a second turn
  into the same Hermes session; a retry from `act` after a failed Enter re-types the transcript into the herdr tab (the text from the first attempt is
  already in the pane). The herdr destination serialises deliveries per pane. Shutdown keeps the window small: `app.stop(true)`, `runner.stop()` (the
  running step finishes, no further step or queued memo starts), `notifyLifecycle.stop()`, `await runner.idle()` + the in-flight
  Live Activity pushes under one 30 s drain deadline (`shutdown.drain_timeout` logs the in-flight memo ids), the APNs transport `close()`, `db.close()`, then a separate 2 s OTel
  flush deadline. The LaunchAgent's `ExitTimeOut` is 60 s to cover it.
- **Devices:** identity is the authenticated device name from the token map, never the body (`name` is a display label).
  `registerDevice` keeps a stored token when the field is omitted or `""` and clears it only on explicit `null`. The
  response reports token presence, never the tokens. `DeviceStore.getDevice` + `getActivityToken` are what the APNs
  notifier reads. Migrations are append-only: `devices` and `activity_tokens` (cascades with the memo) are entry 4.
- **Audio and speech are derived, disk-cached and single-flight:** the recording is `<audio>/<id>/combined.m4a` (mono 16 kHz
  AAC from `ffmpegConcat`, built on the first request; removed with the segments), speech is
  `<IRIS_DATA>/speech/<id>.mp3` with the spoken text in `<id>.txt`, so a retry that changes the variant text re-synthesizes
  instead of replaying stale audio (the key is the derived speech variant, never stored). A failed combine or synthesis caches nothing. `/audio` honours a single `bytes=` range;
  multi-range and malformed headers get the whole body, a range past the end gets 416.
- **Mermaid replies:** after `act` has the reply, `memo/reply-assets.ts` renders every top-level ```mermaid fence through the `DiagramRenderer` port
  (production `adapters/diagram-pele.ts`: Pele for SVG, resvg-js for PNG at 2x, light and dark with the basalt colours resolved into the SVG) and stores four files per block
  under `<IRIS_DATA>/assets/<memo>/<uuid>` with rows in `reply_assets`; the wire carries `replyBlocks` (omitted when empty: `{index, kind, width, height, svg, png}`, each
  `{light, dark}` asset ids; `index` counts the reply's mermaid fences from 0). A block Pele rejects stays a code block (`reply.render_failed`; a failed file write is `reply.store_failed`; more than 12 blocks `reply.blocks_capped`; no asset, never a step failure),
  a changed reply re-renders and prunes the old files; the rows are provisional until `completeStep` commits that reply (a lost compare-and-set removes rows and files); a boot sweep (`ReplyAssets.backfill`, 50 memos per start) renders older replies that have a fence and no rows; the purge removes files before rows. Library choice and why: TDD §3 "Reply assets".
- **audio-gateway timeouts are hang guards:** the STT call (30 min) throws `hangGuardFailure` and the speech call (2 min) a plain 503; neither is retried (one window, then `POST /retry`).
- **Speech request** to audio-gateway: `POST /v1/audio/speech {input, response_format: "mp3"}` with `x-audio-source: iris`.
  No `model` or `voice`: the gateway owns both and detects the language. A non-2xx is 503 `unavailable`.
- **herdr:** one connection per request, newline-delimited JSON, `session.snapshot`, `pane.send_text`, `pane.send_keys` (verified on herdr 0.9.3,
  protocol 22; request shapes in the `adapters/herdr.ts` header). Delivery types the transcript into the tab's agent pane and presses `enter` (the agent's
  answer stays in its terminal, `replyText` is empty). At most 8 deliveries wait per pane; the ninth fails "herdr pane <id> queue is full" (503, not transient).
  A HerdTab is a tab of a non-separator workspace (labels starting `── ` are sidebar dividers), `repo` is the workspace
  label, `agentState` is the tab's `agent_status` (unknown values become `unknown`). The snapshot has no timestamps, so
  `lastActivity` is always null. A 5 s hang guard, a refused connection or a bad answer is 503.
- **Schemas** in `http/schemas.ts` are the contract source: routes use them for `body` / `query` / `params` / `response`,
  and `schemas.test.ts` fails if a Transform sneaks in (the two `t.Numeric` query params are the exception). Elysia's
  own `t.Integer` is a Transform, so integers are `t.Number({multipleOf: 1})`.
- **APNs** (`APNS_KEY_P8` PEM with literal `\n` allowed, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` = bundle id): the
  APNs notifier runs only when all four are set (else the log notifier), and that is deliberately not in `degraded` (the log
  notifier is the intended state until enrolment; a degraded `/health` fails `make verify`). Boot logs `notifier.selected`.
  Environment per push is `device.apnsEnv`, `sandbox` when null; with a null `apnsEnv`
  a BadDeviceToken (likely a production token sent to the sandbox) is logged with a hint and the token is kept, so only
  an explicitly registered env makes BadDeviceToken clear it (410 / Unregistered always do, via the conditional `clearApnsToken`). `notify` sends the Live Activity `end` (if the memo has an
  activity token) and the alert (if the device has an `apnsToken`); neither registered logs `notify.no_token` and succeeds.
  A rejected token never fails the memo: `notify.apns_rejected` is logged, and BadDeviceToken / 410 Unregistered clear the
  stored token (only if it is still the one we sent to); other 4xx (e.g. 403 InvalidProviderToken) are logged, tokens kept.
  Transient failures (status 0, 408, 429, 5xx, 403 ExpiredProviderToken) throw a `TransientError`, so the runner retries notify twice (2 s, 8 s) and then fails it for `POST /retry`
  (a retry re-sends both pushes; the alert carries `apns-collapse-id` = memo id, so a re-send replaces the banner instead of duplicating it). `phase` (Live Activity `update`, priority 5) is bound to memo events by
  `bindPhaseUpdates`: not for `receiving` or `notified`, serialised per memo, latest state wins, errors logged only.
  **Needs-route alert:** `bindNeedsRouteAlerts` calls `notifier.needsRoute({memo, reason})` once when a memo enters `needs_route` (skipped when it was already
  answered): one alert, priority 10, `category: MEMO_NEEDS_ROUTE`, `thread-id: memo`, `mutable-content: 1`, `apns-collapse-id` = memo id, title "Where should this go?",
  body the park reason (never transcript or reply). Alert only: the Live Activity `needsRoute` update is the phase binding's, so nothing is sent twice. Best effort, never
  throws (`notify.needs_route_failed`, `notify.apns_*`); no alert token logs `notify.no_token`; the log notifier logs `notify.needs_route_log`. It is part of the
  shutdown drain (`createNotifyLifecycle({alerts})`). The finished memo's `MEMO_DONE` alert has the same collapse id and replaces the banner.
- **APNs transport:** node-apn builds the ES256 JWT with `jsonwebtoken` and regenerates it when its `iat` is 3300 s (55 min)
  old, checked per request (Apple: not <20, not >60 min); it retries 408/429/5xx and ExpiredProviderToken 3x. We cap in-flight
  streams at 10 (Bun ignores `peerMaxConcurrentStreams`) and send the first request per environment alone (Apple allows one
  stream until a valid token lands; a status-0 failure re-arms that). `config.port` (443) is passed to `http2.connect` and Bun
  honours it over the URL, so a test server needs `address` and `port` both. Not verified: real Apple hosts and GOAWAY JSON.
  node-apn emits a harmless `MaxListenersExceededWarning` (one `timeout` listener per stream on the session) above 10 streams.
- **Live Activity contract (Swift side):** payload `aps` is `{timestamp, event, "content-state"}` (+ `dismissal-date` on `end`,
  now + 15 min). `ContentState` is plain camelCase Codable: `phase` (`processing` | `needsRoute` | `done` | `failed`),
  `routeChip?`, `headline?` (≤ 60), `hasReply`. `inputName` is never sent: the client keeps it device-side and must declare it
  optional. Alerts carry the route chip + headline only (never transcript or reply), `category: MEMO_DONE` (or `MEMO_NEEDS_ROUTE`: generic title,
  the park reason as body), `thread-id: memo`, `mutable-content: 1` and a top-level `memo` id.
- **Bookkeeping failures** (`completeStep` throws after a handler ran) log `runner.bookkeeping_failed`
  and propagate; the step row stays `running` and the memo keeps its state until the next `driveAll`.
- A stored `summary_json` that fails the zod `Summary` schema reads as `null` with a `memo.summary_invalid` log.
- **SSE** has no `Last-Event-ID` replay; clients refetch the list on reconnect.
- **Long polls and SSE** call `server.timeout(request, 0)` to escape Bun's idle timeout.
- **Secrets on the mini:** `secrets-run`, never `op`.
- `server/package.json` is imported by `telemetry/otel.ts` for `service.version`; keep it there.
- **Apple build artifacts:** `xcodebuild` leaves `apple/.dd` and per-package `.dd` / `.build`, and `make screenshot` writes `.artifacts/`; all gitignored.
  `Iris.xcodeproj` is generated: edit `apple/project.yml`, never the project.
- **App composition:** `-IrisFakeCapture` (every UI test, `make run-sim`) runs the fake API, silent media and fake capture; without it the app is
  production: server URL + device token from Settings → Connection (token in the Keychain, URL in `UserDefaults`), one `ReconfigurableAPIClient`
  shared by every model. Nothing saved: the app opens on Settings and loads nothing. Memo audio and speech are downloaded with the bearer header by
  `MediaDownloader` and played from the file (no `AVURLAssetHTTPHeaderFieldsKey`, TDD §4 "Authenticated media"). `MemoPlayer` follows a periodic time
  observer; call `teardown()` when the screen goes away. The unsigned simulator build (`CODE_SIGNING_ALLOWED=NO`) has no Keychain (`-34018`): the
  Keychain round-trip unit test cancels there and is device-verified only. `StatsModel`/`SettingsModel`/`HistoryModel` `load()` drop a stale answer (generation guard).
- **Thread view** (`ThreadView` / `ThreadModel`, TDD §4 "Thread view"): a History row of a chat or a continued thread (`Memo.opensThread`) pushes it; the model derives turns from
  `GET /v1/threads/:id` (user, assistant, pending with step dashes, failed) and reloads on the memos' History revisions. Replies render through `IrisUI`'s `MessageContentView`: `MessageBlock.split`
  cuts markdown into Textual text, a table (grid or cards via `ViewThatFits`) and Mermaid fences numbered like the server's `ReplyBlock.index`; diagrams are the PNG of the current appearance
  through `ReplyImageStore` and the authenticated `MemoMediaSource.asset`. Textual is pinned `exact: 0.5.0` in `IrisUI` only. Voice replies go through the `VoiceReplyCapture` port (fake under
  `-IrisFakeCapture`, unavailable in production until I3). The fake sample data holds a chat thread with every block type (`SampleData.chatThreadID`) and a Hermes thread with a turn in flight.
- **Snapshots** only compare on the pinned simulator; a diff on a clean tree means a different runtime. They do not render the glass layer.
- **`scripts/mbm tap`** needs `--element-ref` from the latest `snapshot-ui` and `--post-delay 2`; `snapshot-ui` straight after a launch times out
  (`make ui-snapshot` waits first). Live Activity, widgets, the notification card and the Mac panel compile but have never been rendered; the
  AVAudioEngine recorder and the interruption paths have never run on a device (`docs/spikes/device-checklist.md`).
- **TDD is the design, code is the truth for shipped behaviour:** §3 was amended in Wave 8 to match the server; planned-but-unbuilt items are marked there.
