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
| `apple/Packages/` | `IrisCore` (models, API client, SSE), `IrisCapture` (session, rotation, outbox), `IrisUI` (Theme from basalt-ui incl. the one spacing scale `Theme.Spacing`, components), `IrisTelemetry` |
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
- `server/src/memo/` — domain: `memo.ts` (states, steps, transitions, `RoutableMode` / `isRoutableMode`: the modes with a route step, i.e. all but `transcribe`), `store.ts` (port), `runner.ts`
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
  and the downstream adapters (`audio-door-client.ts`: the one door client, URL + bearer + `agw-run-id` + hang guard, no redirects; `audio-door.ts`: the transcriber + the ffmpeg combiner; `audio-door-speaker.ts`, Hermes, agw (`agw-client.ts`: the one agent-workflows host client, URL + bearer + `x-agw-purpose` / `x-agw-caller` / `x-agw-project` (all `iris`) + `agw-run-id` + hang guard (an aborted request), no redirects; `agw.ts`: the `triage` summarizer;
  `agw-decider.ts`: the `decide` call),
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
| `POST /memos` `{id, mode: auto\|journal\|hermes\|tab\|chat\|transcribe, startedAt, threadId?}` | 201 memo; 200 if it exists for this device; 409 other device or another `threadId` on the replay; `threadId` continues that thread (delivered into its Hermes session, route forced to hermes), 404 when unknown |
| `POST /memos/text` `{id, mode, startedAt, text, threadId?}` | 202 memo created in `transcribed` (`transcript` = trimmed text, driven from `route`; a replay too); memo carries `typed: true`; any mode incl. `chat`; 400 empty, over 20 000 code points, or no/unknown `mode`; 409 another body (incl. `threadId`), device or a recorded memo with that id; 404 unknown `threadId` |
| `PUT /memos/:id/segments/:n` raw `audio/mp4` bytes | 200, idempotent by sha256 (same sha no-op, different sha 409); 413 over `IRIS_MAX_SEGMENT_BYTES`; 409 after `complete` |
| `POST /memos/:id/complete` `{segmentCount}` | 202 memo (repeat too); 422 `missing_segments` + `missing: [...]` |
| `POST /memos/:id/retry` `{from}` | 202 memo; 409 unless `failed`, or `notified` with `from: "summarize"` when its `summarize` step failed (re-runs summarize, then notify, which re-sends the alert: same collapse id, so it replaces the banner); 400 `from: "transcribe"` on a typed memo, and a `from` the memo's mode has no step for (mode `transcribe`: only `transcribe`, `notify`) |
| `POST /memos/:id/route` `{destination: hermes\|journal\|herdr, tab?}` | `needs_route`: 202 memo, routed and driven on (400 `<dest> not available` when unregistered; `tab` iff herdr); after `act` (`acted`/`summarized`/`notified`): 200 memo, a `correction` is only logged; other states and a second answer 409; 400 for a memo in mode `transcribe` (it has no route to answer or correct); 404 unknown |
| `GET /memos?limit&cursor&q&route&state&favorite&archived&kind` | `{items, pinned, pinnedTruncated, nextCursor}`, newest first; `q` = FTS5 over transcript + headline (prefix, case/umlaut-insensitive), `route` / `state` exact, `favorite=true`, `archived=true` (only archived; hidden otherwise), `kind=chat\|hermes` (thread kind) (unknown 400); soft-deleted memos never listed; open `needs_route` memos (not `done`) are never in `items`, the first page pins them in `pinned` (≤ 50; `pinnedTruncated` true when more matched, false on later pages), later pages `[]`; a `done` one is paged in `items` |
| `GET /memos/:id` | memo + `steps` timeline + `segmentCount`; 404 unknown. A soft-deleted memo is returned too (with `deletedAt` / `purgeAt`); 404 once purged |
| `PATCH /memos/:id` `{done?, favorite?, archived?}` | 200 memo; ≥ 1 boolean, an empty body, unknown key or non-boolean 400; 409 `bad_state` on a soft-deleted memo; 404 unknown; publishes `memo.updated` |
| `DELETE /memos/:id` | soft delete: 200 memo with `deletedAt` + `purgeAt` (10 min later); only `notified` / `failed` / `needs_route` / `receiving` (a cancelled take: its later segment and `complete` are 409 `bad_state`, no pipeline) else 409 `bad_state`; a repeat is idempotent; a segment write still in flight is refused and its file removed right after it lands (recorded segments stay for a restore); the purger then removes audio, speech and rows (`memo.purged`) |
| `POST /memos/:id/restore` | 200 memo, `deletedAt` cleared; 409 when not deleted; 404 once purged |
| `GET /memos/:id/result?wait=<s>` | 200 once result-ready, else 202 after the wait (0..600, default 0) |
| `GET /threads?kind=chat\|hermes&limit&cursor` | `{items: Thread[], nextCursor}`, newest `updatedAt` first; `Thread = {id, kind, title, createdAt, updatedAt, lastMemoId}` |
| `GET /threads/:id` | `{thread, memos (oldest first), messages: [{memoId, role: user\|assistant, content, createdAt}]}`: the conversation is built from the memos' transcripts and replies (Iris's own record, no Hermes read); 404 unknown |
| `POST /devices/register` `{name, platform: ios\|macos, apnsToken?, apnsEnv?, pushToStartToken?}` | 200 `{device, name, platform, apnsEnv, hasApnsToken, hasPushToStartToken, registeredAt}`; upsert by the authenticated device |
| `POST /telemetry` `{resource, spans, logs, dropped}` (the Swift `TelemetryBatch`) | 202 `{accepted: {spans, logs}}`; exported in the background as OTLP with `service.name=iris-ios\|iris-macos`, the memo trace id kept; 413 over 256 KiB, 400 over 500 spans+logs, a schema violation or a bad timestamp |
| `PUT /memos/:id/activity-token` `{token}` (hex) | 204, replaces the stored token; 404 unknown memo |
| `GET /memos/:id/audio` | `audio/mp4`, concatenated on first request and cached; `Range` → 206 / 416; 404; 409 while `receiving` or soft-deleted |
| `GET /memos/:id/assets/:assetId` | a rendered Mermaid file of the reply (ids in the memo's `replyBlocks`): `image/svg+xml` (CSP `default-src 'none'`) or `image/png`, immutable cache; 404 unknown memo or asset; 409 when soft-deleted |
| `GET /memos/:id/speech` | `audio/mpeg` TTS of the speech-ready variant (`speechVariant`: cleaned reply, or `summary.spoken` + "details on screen" past 600 chars; else `summary.spoken`), cached; 404; 409 with neither or when soft-deleted; 503 without the audio door (`AUDIO_DOOR_URL` + `AUDIO_DOOR_TOKEN`) |
| `GET /herd` | `{tabs: [{id, repo, label, agentState, lastActivity}]}` from herdr; 503 without `HERDR_SOCKET` or when herdr is unreachable |
| `GET /stats?days=<n>` | `{days, from, to, perDay, perWeek, stepMedians (per step and route, with n), costPerRoute}` over the last `n` local days (default 30, 1..365 else 400); read-only SQL/JS aggregates, `null` route = `unrouted` |
| `GET /events` | SSE: `ready`, `memo.updated` per state change (and per flag change, delete or restore, without `memo.done`), plus `memo.done` when result-ready, `: keepalive` every 15 s |

Codes: not_found 404, conflict / bad_state / destination_unavailable 409, missing_segments 422, too_large 413, bad_request 400, unavailable 503.
Wire JSON is camelCase.
States: `receiving → received → transcribed → routed | needs_route → acted → summarized → notified`,
with `failed(step)` as a side state.


## Device (the paired iPhone)

`lockf -t 900 /tmp/iris-apple.lock make device` builds, signs, installs, launches Iris and screenshots the phone to `.artifacts/device-<time>.png`
(`device-build`, `device-run`, `device-screenshot` run alone; `make device-run ARGS="-flag"` passes launch arguments). Scripts: `scripts/device-*.sh`;
the phone (`devicectl list devices`, the connected physical iOS device) and the team (`defaults export com.apple.dt.Xcode`) resolve at runtime, nothing
about either is tracked. Overrides: `IRIS_DEVICE_ID`, `TEAM=<id>`, `DEVICE_SIGNING=personal|paid`.
- **Signing is one switch.** `DEVICE_SIGNING=personal` (default) uses the free Personal Team, `DEVICE_SIGNING=paid` the paid team and the entitlements
  exactly as tracked. The three iOS targets' `CODE_SIGN_ENTITLEMENTS` are variables (`IRIS_APP_ENTITLEMENTS` etc. in `apple/project.yml`, default the tracked
  files, so the simulator/CI build with `CODE_SIGNING_ALLOWED=NO` is unchanged); a personal build points them at copies without the gated keys, derived at
  build time from the tracked files (`scripts/device-lib.sh`), so nothing drifts. The three `*.entitlements` files are hand-kept, no longer generated.
- **Gated off for a Personal Team (device builds only):** `aps-environment` (Push/APNs: no remote Live Activity updates, no result notification,
  device registration without an APNs token, spikes S3/D3 wait for the paid team) and `com.apple.security.application-groups` (no Swift code reads the
  App Group yet; the Keychain group stays). Nothing else is gated; Live Activities, the Control widget and the audio background mode need no entitlement.
- **Personal Team limits:** 7-day profiles (rebuild weekly), 10 App IDs per 7 days (`com.jkrumm.iris`, `.widgets`, `.notifications` are three; never rename them),
  3 devices. Only the Iris iOS targets are built; `IrisMac` and the test bundles are not.
- **First install:** the first `-allowProvisioningUpdates` build registers the device; the owner must trust the developer once on the phone (Settings >
  General > VPN & Device Management) or `launch` fails with "invalid code signature ... profile has not been explicitly trusted".
  A codesign keychain prompt on the mini's screen needs "Always Allow" (not seen so far: the build signed headless).
- **Screenshot:** `xcrun devicectl device capture screenshot` (Xcode 27). `pymobiledevice3` does not work here: the phone is on a CoreDevice network tunnel,
  `usbmux list` is empty and an RSD tunnel needs root.
- **Connecting the app** has no launch-argument route (no production backdoor): the owner types the server URL and the `iphone` device token once in
  Settings > Connection (Keychain item survives reinstalls over the same bundle id). The tailnet VPN must be on. The phone must be unlocked for `launch`.
  Verified 2026-10-30: a typed memo from the phone reached `done`. Known app gap: Settings says "Connected" for any saved configuration, reachable or not.

## Validate

| Target | Runs | Where |
|-|-|-|
| `make check` | `check-server` (oxlint, `oxfmt --check`, `tsc --noEmit`, `bun test`), `check-contracts`, `guard`, and `check-apple` wherever `xcodebuild` exists | mini, CI (`check.yml`, no Apple on Linux) |
| `make e2e` | the pipeline against a fake-booted server (needs ffmpeg) | mini, CI after `check` |
| `make check-apple` | Theme drift, `swift format lint --strict`, `swift test` per package (macOS host), `xcodebuild build` of `Iris` + extensions (simulator) and `IrisMac`, then `IrisMacTests` (hosted in the Mac app, `-IrisFakeData`: notifier, composition root, detail model) | mini, CI (`apple.yml`) |
| `make snapshots` | IrisUI snapshot tests on the pinned simulator (`RECORD=1` re-records) | mini, `apple.yml` |
| `make uitest` | XCUITest flows (`-IrisFakeCapture`); `ONLY=<Class>[/<test>]` runs one class or method (`-only-testing:IrisUITests/…`) | full suite: `apple.yml`; mini: `ONLY=` only |
| `make device` | `device-build` + `device-run`: signed Debug build, install, launch and a phone screenshot on the paired iPhone (see Device) | mini, phone wired |
| `make guard` | public-repo scan (IPs, tailnet/real hostnames, token shapes) | mini, CI, lefthook pre-commit |
| `make verify` / `make smoke` | production health / a real recording through production | mini only, after deploy |

The full UI suite is CI's (`apple.yml`; a new push cancels a PR's stale run, never a master run). Locally run `make snapshots` plus `make uitest ONLY=…` for the screens you touched, on one simulator, then `xcrun simctl shutdown all`. Never re-run the full suite locally to bisect: read the CI log and run the failing test alone.

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
`http://127.0.0.1:7730`), `IRIS_TOKEN` (required); flags `--url --token --mode auto|journal|hermes|tab|chat|transcribe
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
  Device tokens and the OTLP endpoint live in `op://mini/iris/*` (listed in
  `dotfiles-private/headless.refs`). Rotate a token: edit the field, `make secrets-seed` from the
  MacBook, `make launchd-restart`. The audio door is not a secret ref: `AUDIO_DOOR_URL` is a plain value in `.env.local.tpl`
  (`http://127.0.0.1:7792/v1`) and `launch.sh` reads the `iris=<token>` line of `~/.agent-workflows/data/door-tokens` (0600, local, owned by
  agent-workflows) into `AUDIO_DOOR_TOKEN` without echoing it; a missing file or line starts degraded (`transcribe`, `speech`) and says why on stderr.
  Rotate it by editing that file and restarting both LaunchAgents. `APNS_*` is unset (no `op://` ref yet, so not in `.env.mini.tpl`; add both at enrolment), so the log notifier runs.
- `HERMES_URL` is composed in `launch.sh` from `HERMES_HOST` + `HERMES_PORT`. The journal takes brain-sync's mkdir lock exactly as `brain/brain-sync.sh` does (own pid in `<lockDir>/pid`; a live pid or a pidless lock under 60 s waits, a dead pid or an older pidless lock is reclaimed; release only while the pid is still ours). It pushes the brain checkout over HTTPS with the mini's headless credential helper (no prompt); `launch.sh` exports `BRAIN_DIR` only when the checkout exists.
- agent-workflows host calls (`POST /triage`, `POST /decide`, synchronous) carry `x-agw-purpose: iris`, `x-agw-caller: iris` and `x-agw-project: iris` (constants in `agw-client.ts`; the run record and the ledger book the spend as caller `iris`, project `iris`; a malformed value is a host 400) and `Authorization: Bearer <AGW_API_SECRET>`; `AGW_API_SECRET` is `op://mini/agent-workflows/API_SECRET` in `.env.local.tpl` (in `headless.refs`). Every answer, errors included, has `agw-run-id`, logged and set on the span as `agw.run_id`. 400, 401 and 502 `INVALID_OUTPUT` are final (any other 502 is transient); 500, 503 and network errors are transient (the runner's retries); the step error carries status, host code and run id, never the body (`agw.error_body` logs the code and the body length, `agw.response_unreadable` the parser message); a 5xx whose body stalls past the guard is a hang guard failure; the hang guard (30 min) aborts the request and is not transient. `costUsd` null is stored as null, never 0. `make verify` also probes `GET http://127.0.0.1:7791/health`.


## Verify & Monitor

- `make verify` — exit 0 iff `GET /health` answers `status: ok` (public; `{status, degraded[], inflight}`) and the audio door's
  `GET http://127.0.0.1:7792/health` does too (the downstream check).
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
- **Downstream env** (all optional, empty = unset): `AUDIO_DOOR_URL` (https or a loopback host, else the start fails) + `AUDIO_DOOR_TOKEN` (both, for `transcribe` and `speech`), `AGW_URL` (https or a loopback host) + `AGW_API_SECRET` (both, for `triage` and `decide`), `HERMES_URL` +
  `HERMES_TOKEN`, `HERDR_SOCKET` and `BRAIN_DIR` (`launch.sh` sets each on the mini only when it exists: the herdr socket, `~/SourceRoot/brain`; a herdr started after iris needs `make launchd-restart`). Each of
  `BRAIN_DIR` (journal), `HERDR_SOCKET` (herdr, also the herd) and `HERMES_*` registers its destination on its own; a missing one is not
  `degraded`, `act` is only when none is registered. Without the rest, `/health` lists `transcribe` /
  `summarize` / `act` / `speech` / `herd` in `degraded`; the first park memos before that step, `summarize` never does: it always has a handler (journal and herdr use a template; a hermes memo without a summarizer fails the step, which is skipped, see **Summarize is optional**), the last two
  answer 503 `unavailable`.
- **Chat mode and threads** (TDD §3 act, data model): mode `chat` routes to hermes (source `mode`, never prefix or `decide`); `act` passes `chat: true` to
  `Destination.deliver`, and the Hermes adapter then opens its session with `source: "iris-chat"` and sends a no-side-effects `system_message` on every turn
  (Hermes' per-turn ephemeral system prompt, not stored). Hermes maps unknown `source` values to `api_server`, so `threads.kind` (`chat|hermes`) is the
  marker, not Hermes. The Hermes adapter names the thread in its `Delivery.thread` (`{id, kind, title}`, id = session id = `destination_ref`); `act` persists it
  (`patch.thread`: `completeStep` upserts the `threads` row and sets the `act`-owned `memos.thread_id`). The memo wire carries `threadId`, omitted when null.
  Continuing a thread: `threadId` on either create route (404 unknown thread, 409 `destination_unavailable` while hermes is not registered, 409 on a replay naming another; `continuedThread` in `memo.ts` tells a continuation from a memo's own
  session, whose id is the memo id), the route step forces `hermes`, `deliver({threadId})` talks into the existing session and `chat` comes from the thread's kind. Turns into one thread run one at a time (`memo/keyed-queue.ts` in the `act` handler; the second waits, at most 30 min: then `act` fails "thread <id> is busy" naming the memo ahead and its task never runs, the line stays ordered; a waiter parked there releases its `driveAll` slot through the handler's `whileWaiting` and takes one again when its turn comes; herdr's per-pane queue holds at most 8 deliveries (`maxPaneQueue`), the ninth fails "herdr pane <id> queue is full", not transient). `/threads/:id`
  builds its conversation from the thread's memos (transcript = user, `reply_text` = assistant), never from Hermes. Swift: `MemoMode` decodes an unknown value to `.unknown`.
- **Mode `transcribe`** (TDD §3 state machine): the pipeline is `transcribe` → `notify` (`memo.ts` `stepsOf(mode)`; `nextStep`, `advance` and `stateBefore` take the mode), the memo ends
  `notified` with the transcript and NULL `route`, `reply_text` and `summary`, with no route, act or summarize row on the timeline and no `route_decisions`; the alert headline is the
  transcript's start. A typed memo in this mode runs `notify` only; `threadId` with it is 400; `POST /retry` from a step the mode lacks is 400. Swift: `MemoMode.transcribe`, offered by
  `MemoMode.voiceModes` (and, as a typed memo, the composer); `PipelineSteps.applicable(to:)` gives such a memo two steps.
- **Routing** (`routing/`, TDD §3 step 3), in order: a mode other than `auto` wins (source `mode`); a spoken prefix within the first 6 words
  (`journal|tagebuch`, `an hermes|hermes`, `tab <name>`; case and diacritics folded; the name may be several words, the longest live tab or repo label wins) routes (`prefix`); `memo.transcript` stays the raw speech-to-text and `act` / `summarize` cut the prefix again via `deliveredTranscript` by the `prefix_words` count the decision row recorded;
  with fewer than two registered destinations the only one wins (`default`, confidence 1, no spend); two or more (production since Wave 11: journal, herdr, hermes; `IRIS_FAKES` registers all three) turn the decider on; otherwise `Decider` (agw `decide`, the host client's hang guard): confidence ≥ 0.8 routes, else `needs_route`. A mode or prefix
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
- **Summarize is optional** (`OPTIONAL_STEPS` in `memo/memo.ts`): when `summarize` fails for good (after the runner's automatic retries; agw `triage` error, a 402, no summarizer for a hermes route), `runner.runStep` calls `store.skipStep`: the step row stays `failed` (error and attempts kept), the memo moves `acted` → `summarized` (not `failed`, `failedStep`/`error` stay null), `notify` runs and the memo ends `notified` with `summary` null, a `step.skipped` log line and a `memo.updated` (step `summarize`). Every other step still fails the memo. `notify` announces `memo.summary ?? ` the delivered transcript clipped to a 60-character headline (`transcriptSummary` in `pipeline/steps.ts`, not stored; the payload builders still take a `Summary`); that is the one place transcript text reaches an alert. `POST /retry {from: "summarize"}` also works on such a `notified` memo (`resetForRetry`: `notified` with a failed `summarize` row), resets it to `acted`, re-runs summarize and notify. `/speech` on a reply with no summary speaks the clipped cleaned reply (`speechVariant`), no 409. History and `memo.summary` null: clients show the transcript. Repair: `repairFailedSummaries` (`adapters/sqlite-repair.ts`, run at boot in `index.ts` after the store opens) moves `failed(summarize)` memos with a reply to `notified` (no push, step row kept), after `VACUUM INTO <IRIS_DATA>/iris.db.bak-<timestamp>`; nothing to repair, no backup; idempotent.
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
  under `<IRIS_DATA>/assets/<memo>/<uuid>`, staged with the store (`stageReplyAssets`, no row yet) and written to `reply_assets` by the `completeStep` that commits that reply; the wire carries `replyBlocks` (omitted when empty: `{index, kind, width, height, svg, png}`, each
  `{light, dark}` asset ids; `index` counts the reply's mermaid fences from 0). A block Pele rejects stays a code block (`reply.render_failed`; a failed file write is `reply.store_failed`; more than 12 blocks `reply.blocks_capped`; no asset, never a step failure),
  a changed reply re-renders and prunes the old files once its commit wins; a lost compare-and-set leaves the earlier reply's rows and files and removes only the new attempt's files; a boot sweep (`ReplyAssets.backfill`, 50 memos per start) renders older replies that have a fence and no rows; a boot sweep (`ReplyAssets.sweep`, 200 memo directories per start, `listMemos` stat-ing 32 at a time, skipping a directory that vanished and skipping and logging (`reply.sweep_failed`, its name) one that cannot be stat-ed; `reply.sweep` logs `skipped`, the directories the limit left, null when the listing failed) removes asset files no row names and no in-flight attempt holds (a crash between commit and prune), logging them as `reply.orphans_removed`; a memo whose blocks Pele all refused (not a failed file write) carries `memos.reply_assets_failed` (migration 13) and is skipped until its reply changes; the purge removes files before rows. Library choice and why: TDD §3 "Reply assets".
- **Audio door timeouts are hang guards:** the STT call (30 min) throws `hangGuardFailure` and the speech call (2 min) a plain 503; neither is retried (one window, then `POST /retry`).
- **Audio door** (agent-workflows `audio` process, `AUDIO_DOOR_URL` = `http://127.0.0.1:7792/v1`, bearer `AUDIO_DOOR_TOKEN`; contract: agent-workflows `packages/audio/README.md` "The door on the process"):
  `POST /audio/transcriptions` (multipart) and `POST /audio/speech`, OpenAI-compatible. Every answer, errors included, carries `agw-run-id`, the
  run that records the call and its cost; both adapters put it on the span and the `audio_door.*` log lines as `agw.run_id` (the old `x-audio-source`
  attribution is gone). A 401 (`{error:{message:'unauthorized'}}`, an unknown or rotated token) is a plain, non-transient failure.
- **Speech request** to the door: `POST /audio/speech {input, response_format: "mp3"}`.
  No `model` or `voice`: the door owns both and detects the language. A non-2xx is 503 `unavailable`.
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
- **Apple build artifacts:** `xcodebuild` leaves `apple/.dd.noindex` and per-package `.dd.noindex` / `.build`, and `make screenshot` writes `.artifacts/`; all gitignored.
  `Iris.xcodeproj` is generated: edit `apple/project.yml`, never the project.
- **Capture and outbox** (Wave 15 I3, TDD §4): `IrisCapture` holds `CaptureSession` (one take: session, route, recorder, outbox) and the persistent `Outbox`, a queue of whole items
  (typed memo, chat message, voice take, thread reply) with `create` → segments → `complete`, idempotent by memo id, jittered bounded backoff, stall after 10 failures or a 4xx a retry cannot fix, "retry now" and "discard". The app reaches it through
  `OutboxService` (a lazy `CaptureStack`; `APIOutboxUploader` is the `SegmentUploader` over `APIClient`); the composer, the thread's `OutboxVoiceReplyCapture`, the Settings queue and `StartMemoIntent` (`Iris/Intents/`, compiled into the widget too) all go through it.
  A take is created on the server at its first segment, so a cancelled take leaves nothing behind. An outbox file that cannot be decoded is never emptied: Settings "Reset outbox" renames it to `outbox.quarantined-<UTC timestamp>.json` (kept, shareable from Diagnostics, its segment files untouched) and opens a fresh queue (`-IrisFakeUnreadableOutbox` shows it on fakes). A startup sweep (`Outbox.sweepOrphans(using:)` over the `SegmentFileStore` port) of the capture directory adopts segment files no record names into the take they belong to (the next index too for a finished take whose `complete` was never handed out, `OutboxMemo.completeMayHaveLanded`) or moves them to `capture/quarantine/`; nothing is deleted, and Settings shows what is kept (count, size, a share of the list; past 50 files or 200 MB a note, never an automatic delete). A file the sweep cannot move stays put, is retried at the next launch and is listed in Settings (`SweepReport.stuck`, `Outbox.strayFiles()`). A second Reset tap mid-reset joins the first. `Outbox.resume()` saves the dispatched state before it starts a transfer. A failed take whose recorder cannot be stopped is finished without the user: with its tail when the recorder queued one, else after the grace period (the user's stop leaves the finish to the pump, so a queued tail is never overtaken). The audio session stays active until every recorder stop has returned (a failed take's too), and is deactivated then, behind the take gate. `complete` answered 422 `missing_segments` sends the listed segments again (`MissingSegmentsError`) instead of stalling. `OutboxMemo.completeMayHaveLanded` is always written; a queue file from before it reads "may have landed" (no tail grows a completed take). `CaptureSession.stop()` / `cancel()` wait at most 10 s for `recorder.stop()` and for the recorder's last event (then the take ends with what closed and `TakeResult.failure`, or throws `recordingFailed`); a stop that timed out leaves the memo open for the tail segment and the `stopped` event (finished after a second 10 s with what closed if it never comes), so the tail is uploaded; a `recorder.stop()` that never returns refuses the next `start` until it does; `TakeController.start` is single-flight and its `cancel()` throws when the session cannot be opened. `start` / `stop` / `cancel` of a take are serialised (a gate in `CaptureSession`); `CaptureStack` never falls back to an in-memory queue (an unreadable or undecodable store refuses new items, is left untouched and is retried; an item whose write fails is refused too); Settings hides Discard on a row that is still recording, and the Live Activity follower ends the activity on a stall or discard, not on a retryable failure; `endOrphans()` (also run on a connection change) spares the takes this process is driving, and `ActivityTokenRegistrar` keeps one `PUT` per memo in flight so an older token never lands after a newer one (the gate is per memo id, so it survives `finish` + `begin` of the same memo). `JSONFileOutboxStore(segmentDirectory:)` saves each segment by file name and resolves it against the current capture directory on load (an install over the app gives the data container a new path, which stalled every segment of the first device take as "the recording file is gone"); old absolute paths are healed and a segment stalled on one is retried once. `APIOutboxUploader` answers a segment `PUT`'s 409 `bad_state` (the memo left `receiving`) by asking the server what it holds: the index is below its `segmentCount` → delivered; otherwise the file is the only copy and is set aside (`keeping`, the sweep's `quarantine/`), never deleted. A create that was on the wire at a kill is re-sent after relaunch, and a discard before that deletes the memo (the dispatch is saved before the request goes out). `LiveActivityPhase` has the client-only `recording` / `paused` / `uploading` (the wire and fixtures keep four). `StartMemoIntent` is `AudioRecordingIntent, LiveActivityIntent`: the second is what makes a control run it in the app process (otherwise it runs in `IrisWidgets`, finds no handler and does nothing). Without a push token (Personal Team) a handed-over Live Activity is ended by the app (`StaleActivityRule` / `StaleActivitySweeper` in `TakeLiveActivity.swift`: polled until the memo is finished, swept at launch, displaced by a starting take; older than 1 h always ends). An activity remembers its server (`MemoAttributes.serverKey`, a digest of the URL): after a server-URL switch the new server's 404 does not end it (it is not asked about; only age ends it). The launch sweep asks about all activities at once, is single-flight, is repeated on foregrounding (a follower does not poll while suspended), and every end is logged with its reason. Device-only: Control press, background take, Bluetooth, Live Activity rendering.
- **App composition:** `-IrisFakeCapture` (every UI test, `make run-sim`) runs the fake API, silent media and fake capture (the real outbox on fake audio; `-IrisFakeOffline` fails the first create of each kind); without it the app is
  production: server URL + device token from Settings → Connection (token in the Keychain, URL in `UserDefaults`), one `ReconfigurableAPIClient`
  shared by every model. Nothing saved: the app opens on Settings and loads nothing. Memo audio and speech are downloaded with the bearer header by
  `MediaDownloader.shared` (one `URLSession`, single-flight per URL, `evict(memoID:)` when History deletes or hides a memo (the cache check runs on the same actor as eviction, and a launch sweep removes cached files untouched for 14 days): it returns at once, scans off the main actor and cancels that memo's downloads still on the wire, so none lands afterwards) and played from the file (no `AVURLAssetHTTPHeaderFieldsKey`, TDD §4 "Authenticated media"). `ReplyImageStore` loads at most three files at once. `MemoPlayer` follows a periodic time
  observer; call `teardown()` when the screen goes away. The unsigned simulator build (`CODE_SIGNING_ALLOWED=NO`) has no Keychain (`-34018`): the
  Keychain round-trip unit test cancels there and is device-verified only. `StatsModel`/`SettingsModel`/`HistoryModel` `load()` drop a stale answer (generation guard). Settings' server row is `ConnectionStatusLine(connection:link:)`: the health probe from when Settings appeared plus `HistoryModel.link` (`ServerLink`: what the event stream and list loads last saw), so a dropped network or Tailscale, or a gateway 502/503/504 without a contract body (a proxy in front of a server that is not answering), reads "Unreachable" with "Server not reachable — is Tailscale on?" and a 401 "Token rejected" instead of a stale "Connected". When the two disagree the newer observation wins (`SettingsModel.probedAt` vs `HistoryModel.linkObservedAt`).
- **Thread view** (`ThreadView` / `ThreadModel`, TDD §4 "Thread view"): a History row of a chat or a continued thread (`Memo.opensThread`) pushes it; the model derives turns from
  `GET /v1/threads/:id` (user, assistant, pending with step dashes, failed) and reloads on the memos' History revisions. Replies render through `IrisUI`'s `MessageContentView`: `MessageBlock.split`
  cuts markdown into Textual text, a table (grid or cards via `ViewThatFits`) and Mermaid fences numbered like the server's `ReplyBlock.index`; diagrams are the PNG of the current appearance
  through `ReplyImageStore` and the authenticated `MemoMediaSource.asset`. Textual is pinned `exact: 0.5.0` in `IrisUI` only. Voice replies go through the `VoiceReplyCapture` port (`OutboxVoiceReplyCapture`: the real
  capture session and outbox, on fake audio under `-IrisFakeCapture`). The fake sample data holds a chat thread with every block type (`SampleData.chatThreadID`) and a Hermes thread with a turn in flight.
  `ThreadReplyBar` is one row of icons (keyboard, hold to talk, locked recording = tap to start, send or cross to end; both voice takes use the same `beginVoice`/`endVoice`). Code is highlighted with the JetBrains
  Light/Dark colors of `IrisUI/Theme/CodeColors.swift` (hand-written, not generated: basalt-ui has no syntax tokens; table in TDD §4 "Reply layout and code themes"); Textual tokenizes after the first frame, so snapshots show no token colors.
- **Capture and outbox failures:** the outbox stalls a transfer on a refusal (`PermanentTransferError`) or after 10 non-transient failures; no network, a
  5xx, a 408 and a 429 are `TransientTransferError` and never count. `OutboxService.resume()` skips the backoff (launch, new connection settings, app
  foreground); it does not touch a stalled item. A recorder `.failed` event puts the take in phase `failed`; `CaptureSession.stop()` throws
  `CaptureError.recordingFailed` when nothing was kept. A segment is withheld from upload until a save that carries it has landed (retried on a timer, `Outbox.saveFailure()` shows in Settings). `SendOutcome.stalled` is a refusal the server will repeat: the composer keeps the text and shows the reason, and the item is not left in the queue. Live Activity calls name the memo (`TakeLiveActivity` is per memo, one follower each). A take cancelled (or an item discarded) after the server may have created its memo
  queues a `DELETE /v1/memos/:id` (`OutboxDeletion`, persisted, retried with backoff, done only on a 200 / 404 / 409; a stall stays in the queue as a "Discarded memo" row with Retry now / Stop trying and is never dropped; it waits for a `create` still on the wire; queued whenever `OutboxItem.createMayHaveLanded` (the create was handed out and not refused), also after a lost answer or a kill, never for a refused create): the take leaves the queue at once, `CreatedMemoLog.forget` makes History hide it (only once the outbox opened)
  (`HistoryModel.hide`, kept out of loads and late inserts), and a late segment or `complete` (409 `bad_state`) finds nothing queued, so it is dropped, never a stall.
- **Optional summarize, money, offline History** (Wave 16 I2, TDD §4): a `notified` memo with `summary == null` reads as done; History and the detail header show the transcript clipped to 60 characters, and the waterfall shows its failed `summarize` as failed-but-optional (`StepWaterfallRow.optionalNote`) with [Retry from Summarize]. Money is `StepText.dollars` (locale, no fixed `$`; two decimals from a cent, four below so a real cost never reads `$0.00`, `<$0.0001` under a hundredth of a cent, zero `$0`). The detail's waterfall is collapsed to its total line (`MemoDetailModel.isWaterfallExpanded`, a failed memo opens it) with contiguous bars (`WaterfallBuilder`); transcript and reply copy as plain text (`MemoDetailModel.copy`, `PlainMarkdown`); the take's meter is `InputLevel` (dB scale, −50…−10 dBFS). History without a saved connection shows a connect prompt that opens Settings. History's hidden set (discarded takes whose server `DELETE` is pending) is persisted (`HiddenMemoStore`) and cleared by `CreatedMemoLog.settle`. The fake API answers a typed memo (`FakePipelineUploader.create`). Every UI test class derives from `IrisUITestCase` (starts the app through `start(_:)`, ends it at teardown, tolerates a stalled terminate).
- **Take UI** (Wave 15 I4, TDD §4 Screens): one `TakeController` (start with its Live Activity, stop, cancel, pause, mic switch; the intents and the screens share it) under a `TakeModel` that follows `CaptureSession.updates()`. A running take is the full `TakeScreen` (a cover, opened on start), or the compact `TakeBanner` once minimized:
  every screen pins it under its navigation bar with `.takeBanner()` (a banner over the whole `TabView` would cover the bar's buttons). The record control is the tab bar's bottom accessory (`RecordAccessory`: tap = Auto, long press = pick a mode; `isEnabled:` hides it during a take on iOS 26.1+, disabled on 26.0);
  memo detail and thread hide the tab bar, so they have no record control (the banner still shows). A take bound to a thread (the thread's hold-to-talk) is not shown by the banner. The Live Activity views are IrisUI's (`LiveActivityPanel`, `Island*`, `ActivityStageDashes`; plain `ActivityPresentation` values, no IrisCore) and the widget maps `ContentState` onto them;
  Stop / mic swap / pause are `LiveActivityIntent`s (`StopMemoIntent`, `SwitchInputIntent`, `PauseMemoIntent`) that call the same `TakeController`. The step progress of a processing memo is the four stages record, upload, process, done from the phase alone (`ContentState` has no step field; per-step progress needs the server to push one). A new take's activity says "N earlier memos are still sending" in `headline` (client phases only).
- **Routing on iOS** (Wave 16 I3, TDD §4 "Routing on iOS"): `ModePicker` is the one mode chip row (composer, and the record control's long-press menu → "Choose mode…" → `RecordModeSheet`; voice takes offer Auto, Journal, Hermes, Chat, Transcribe). `RouteAnswerModel` / `RouteAnswerSheet`
  answer a parked memo and correct a finished one through `POST /v1/memos/:id/route` (pinned History row swipe action, detail card, "Wrong route?"; one `routeAnswerSheet(item:make:onRouted:)` modifier, hosted by `RootView` for rows and by the detail for itself, never by `HistoryView`; herdr needs a tab from `GET /v1/herd`; 400 `<dest> not available` and 409 are sentences on the sheet). `SpeechPlayer` is the one spoken-reply player (`Memo.isSpeakable`, notified + a reply + not deleted, is the one rule: the media sources, hence Play and `PlayReplyIntent`, and `SpokenReplies`): the detail's Play,
  `PlayReplyIntent` (an `AudioPlaybackIntent` in `Iris/Intents`, compiled into the widget; the done Live Activity has a Play button, compile-checked only) and spoken replies (Settings toggle, `SpokenReplies`: foreground only, memos this device created, once each; the take sample is taken when `memo.done` arrives, not after the task hop); it never interrupts: while a reply or the open detail's recording plays or any take is open (`TakeModel.isCapturing`) the memo is skipped for good, no queue (Wave 17 I3). The other direction (Wave 18 I1): `TakeController.captureActive` is one synchronous flag, set before a start awaits anything (a thread's hold-to-talk too, `OutboxVoiceReplyCapture.claim`) and cleared only after the session has ended; a start also pauses the reply, the open detail's recording and any speech still downloading (`SpeechPlayer.pauseForTake()`). Every playback start reads the flag at the moment it starts (`SpeechPlayer.captureActive`); nothing resumes by itself. Settings → Microphone edits the active route's mic rule (`MicRulesModel` over `RouteManager`;
  `RouteSnapshot.outputNames` is display only). The fake API's needs-route sample has a reason + suggestion and `SampleData.herd` has two tabs.
- **Spacing:** no spacing literals in views; `Theme.Spacing` (`IrisUI/Theme/Spacing.swift`) holds the steps (`hair` 2 … `xl` 24) and the roles (`screenMargin` 20, `sectionTop`/`sectionBottom`, `titleTop`, `rowVertical`, `rowColumnGap`, `rowLineGap`, `chipGap`, `barInset`, `barGap`, `cardInset*`), taken from the mockups' CSS. A missing value is added there with its mockup source. Control sizes (button and dash dimensions) are not spacing.
- **Strings:** `String(localized:)` everywhere; IrisUI has `Resources/Localizable.xcstrings` (en, de), the app target has `Iris/Resources/Localizable.xcstrings` with the one string that has a `de` entry so far (the too-short toast). The rest of the app target is source-language until R5.
- **UI test waits:** a test never reads `exists`/`frame` of an element that may not be there in a loop; it uses `IrisUITestCase.waitForPresence` / `waitForAbsence` / `revealRow(containing:in:)`, which ask again when a query times out on a loaded runner (TDD §4 "UI tests on the hosted runner").
- **UI tests and the clock:** the fake sample memos are relative to a clock, and the UI tests pin it (`-IrisSampleNow <ISO-8601>`, `Tests/UITests/SampleClock.swift`: noon today),
  so History looks the same at 00:30 and at 14:00 (a memo from 90 minutes ago is on another day for the first hour and a half after midnight). The fake
  server's clock starts there and runs on, so a memo created in the app is newer than the samples. `HistoryDaySection.id` is (day, occurrence): a pinned
  `needs_route` memo from yesterday and yesterday's own memos are two sections of one day and must not share an id (SwiftUI dropped the rows).
- **Snapshots** only compare on the pinned simulator; a diff on a clean tree means a different runtime. They do not render the glass layer.
- **Mac notifications** announce only a live `memo.done` from the open event stream; a memo that finished while the stream was down is not announced
  (known limit, no catch-up; the list reloads on reconnect). Banners never carry the transcript, reply or park reason (TDD §5).
- **`scripts/mbm tap`** needs `--element-ref` from the latest `snapshot-ui` and `--post-delay 2`; `snapshot-ui` straight after a launch times out
  (`make ui-snapshot` waits first). Live Activity, widgets and the notification card compile but have never been rendered; the Mac panel renders on the mini
  (`IrisMac -IrisFakeData -IrisMacPanelWindow -IrisMacSnapshot <dir>` writes PNGs of its own windows; `screencapture` has no Screen Recording grant there); the
  AVAudioEngine recorder and the interruption paths (incl. the lock-time interruption fix of Wave 17 I7: reactivate the session,
  rebuild the engine, auto-finish a failed take) and the engine restart on a route change (fresh engine, validated tap format, `IrisObjCGuard` shim) are covered by fakes only until the device check passes (`docs/spikes/device-checklist.md`).
- **TDD is the design, code is the truth for shipped behaviour:** §3 was amended in Wave 8 to match the server; planned-but-unbuilt items are marked there.
