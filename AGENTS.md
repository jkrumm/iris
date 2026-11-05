# iris — Agent Instructions

Voice channel into the agent platform. A memo recorded on a phone is uploaded as 10 s segments, transcribed, handed to Hermes (which decides what it is and acts)
and notified. A public monorepo: `server/` (Bun + Elysia + `bun:sqlite`, runs on the mini), `apple/` (iOS app, Mac app, packages),
`contracts/` (the wire contract both sides test against). **`docs/TDD.md` is the design, `docs/PRD.md` is the product, `docs/waves/PLAN.md` is
the implementation chain** (foundation waves, then the fleet backlog). Read the TDD section named by a rule before changing that area.

## Layout

| Path | Holds |
|-|-|
| `server/` | iris-server: memo domain, HTTP, adapters, telemetry (detail below) |
| `contracts/` | `schema/*.json` (generated), `fixtures/*.json` (hand-written, Swift decodes every one), `manifest.json` (every route) |
| `apple/project.yml` | XcodeGen spec: `Iris`, `IrisWidgets`, `IrisNotifications`, `IrisMac`, `IrisUITests`; `Iris.xcodeproj` is generated and gitignored |
| `apple/Packages/` | `IrisCore` (models, API client, SSE), `IrisCapture` (session, rotation, outbox), `IrisUI` (Theme from basalt-ui incl. the one spacing scale `Theme.Spacing`, components), `IrisTelemetry` |
| `apple/{Iris,IrisWidgets,IrisNotifications,IrisMac}` | thin app targets (`IrisWidgets`: the Record control, the Live Activity, `HomeWidgets.swift` = `RecordWidget` + `LastMemoWidget`); `apple/Tests/UITests` XCUITest smoke; `apple/tools/` Theme generator (Bun) |
| `scripts/` | `send-memo.ts` (driver), `check-strings.ts` (catalog check), `e2e.ts`, `smoke.sh`, `launch.sh`, `mini-deploy.sh`, `public-guard.ts`, `mbm` (mobilebuildmcp CLI wrapper) |
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
- `server/src/memo/` — domain: `memo.ts` (states, steps, transitions, `runsAct`: every mode but `transcribe` hands the memo to Hermes; `normalizeKind` / `normalizeActions`, `OPTIONAL_STEPS`), `store.ts` (port), `runner.ts`
  (idempotent step runner, concurrency-bounded `driveAll`, `idle()`), `service.ts` (`MemoService`, what HTTP calls), `media.ts`
  (`MemoMedia`: the combined recording and the spoken result, both disk-cached and single-flight), `speech-text.ts` (`speechVariant`: the markdown-free, length-capped text `/speech` synthesizes, TDD §3), `keyed-queue.ts` (one Hermes thread's turns run one at a time), `events.ts` (in-process
  pub/sub), `purge.ts` (the purger: removes soft-deleted memos' files and rows after the 10-minute undo window), `errors.ts` (`MemoError` codes, `configured()` for optional subsystems), `test-support.ts` (fake audio, seeded and parked memos).
- `server/src/pipeline/steps.ts` — `createStepHandlers`: the four step handlers (`transcribe`, `act`, `summarize`, `notify`), each a pure function
  of (memo, ports); a handler is registered only when its port is provided (`act` needs the Hermes destination); `summarize` is always registered (no summarizer = the step fails and is skipped).
- `server/src/adapters/` — `sqlite.ts` (+ `sqlite-migrations.ts`, `PRAGMA user_version`; migration 7 adds the `memo_fts` FTS5 index behind history search, 14 the Hermes-decides columns), `sqlite-devices.ts`
  (`DeviceStore`, same db), `sqlite-threads.ts` (`ThreadStore`: the thread read queries, composed into the memo store), `sqlite-stats.ts` (`StatsStore`: read-only aggregates behind `GET /stats`), `audio-fs.ts` (segments + `combined.m4a`), `speech-fs.ts` (`<id>.mp3` + `<id>.txt`), `assets-fs.ts` (`<id>/<asset id>` reply assets), `diagram-pele.ts` (`DiagramRenderer`: Pele + resvg-js; migration 11 adds `reply_assets`),
  and the downstream adapters (`audio-door-client.ts`: the one door client, URL + bearer + `agw-run-id` + hang guard, no redirects; `audio-door.ts`: the transcriber + the ffmpeg combiner; `audio-door-speaker.ts`; `agw-client.ts`: the one agent-workflows host client, URL + bearer + `x-agw-purpose` / `x-agw-caller` / `x-agw-project` (all `iris`) + `agw-run-id` + hang guard, no redirects; `agw.ts`: the `triage` summarizer; `hermes.ts`: the one `Destination` (session, turn over SSE, the ```iris block, tool names); log notifier), and the APNs pair: `notifier-apns.ts` (`Notifier` over an `ApnsTransport`)
  and `apns-node.ts` (the transport on `@parse/node-apn`; `apns-test-support.ts` generates test keys and certs).
- `server/src/ports/` — `audio.ts` (`AudioStore`, `AudioCombiner`, `Recording`), `clock.ts` (system, fixed and manual clocks),
  `transcriber.ts`, `speaker.ts` (+ `SpeechCache`), `devices.ts` (`DeviceStore`: devices, APNs tokens, Live Activity tokens), `diagram.ts` (`DiagramRenderer`), `assets.ts` (`AssetStore`),
  `stats.ts` (`StatsStore`), `summarizer.ts` (`Summarizer`), `destination.ts` (`Destination`: the Hermes port, `Delivery` + `DeliveryMeta`), `notifier.ts` (`notify` + best-effort `phase`),
  `apns.ts` (`ApnsTransport`), `fakes.ts` (in-memory fakes of the ports, incl. `fakeApnsTransport`).
- `server/src/notify/` — `payloads.ts` (pure alert / Live Activity builders), `phases.ts` (`bindPhaseUpdates`: memo events →
  `notifier.phase`), `select.ts` (`selectNotifier`: APNs or log, plus the transport's `close`),
  `lifecycle.ts` (`createNotifyLifecycle`: stop / idle / close for shutdown).
- `server/src/http/` — `auth.ts` (device-token guard), `memos.ts`, `devices.ts`, `media.ts` (audio + speech, `Range`; reply assets),
  `threads.ts` (`/threads`), `stats.ts`, `events.ts` and `telemetry.ts` (route plugins; `telemetry.ts` reads and validates its own body), `schemas.ts` (every request/response shape as pure TypeBox, exported for the
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
| `POST /memos` `{id, mode: hermes\|transcribe\|auto\|chat\|journal\|tab, startedAt, threadId?}` | 201 memo; 200 if it exists for this device; 409 other device or another `threadId` on the replay; `threadId` continues that thread (delivered into its Hermes session), 404 when unknown; the mode is stored as received (`auto`, `chat`, `journal`, `tab` are what the installed app still sends: Hermes gets them as a hint line) |
| `POST /memos/text` `{id, mode, startedAt, text, threadId?}` | 202 memo created in `transcribed` (`transcript` = trimmed text, driven from `act`; a replay too); memo carries `typed: true`; any mode; 400 empty, over 20 000 code points, or no/unknown `mode`; 409 another body (incl. `threadId`), device or a recorded memo with that id; 404 unknown `threadId` |
| `PUT /memos/:id/segments/:n` raw `audio/mp4` bytes | 200, idempotent by sha256 (same sha no-op, different sha 409); 413 over `IRIS_MAX_SEGMENT_BYTES`; 409 after `complete` |
| `POST /memos/:id/complete` `{segmentCount}` | 202 memo (repeat too); 422 `missing_segments` + `missing: [...]` |
| `POST /memos/:id/retry` `{from}` | 202 memo; 409 unless `failed` (or the `notified` case below); 400 `from: "transcribe"` on a typed memo, and a `from` that is not a step of the memo's pipeline (`transcribe`, `act`, `summarize`, `notify`; mode `transcribe`: only `transcribe`, `notify`) or lies after the step that failed; an old memo that failed at `route` retries from `act`; also 202 for a `notified` memo with `from: "summarize"` when its `summarize` step failed (re-runs summarize, then notify, which re-sends the push by the notify rule: the `end` with its alert, else the alert push, whose collapse id replaces the banner) |
| `GET /memos?limit&cursor&q&state&favorite&archived&kind&thread` | `{items, nextCursor}`, newest first; `q` = FTS5 over transcript + headline (prefix, case/umlaut-insensitive), `state` exact, `kind` = the memo's kind, exact after the same normalisation as the stored one (`GET /memos?kind=%20Note` finds `note`), `thread=true` the memos of a conversation (a thread with at least two live memos, i.e. a continued one; a memo alone in its own session is none), `favorite=true`, `archived=true` (only archived; hidden otherwise); soft-deleted memos never listed; old `needs_route` memos are paged like any other |
| `GET /memos/:id` | memo + `steps` timeline + `segmentCount`; 404 unknown. A soft-deleted memo is returned too (with `deletedAt` / `purgeAt`); 404 once purged |
| `PATCH /memos/:id` `{done?, favorite?, archived?}` | 200 memo; ≥ 1 boolean, an empty body, unknown key or non-boolean 400; 409 `bad_state` on a soft-deleted memo; 404 unknown; publishes `memo.updated` |
| `DELETE /memos/:id` | soft delete: 200 memo with `deletedAt` + `purgeAt` (10 min later); only `notified` / `failed` / `receiving` (a cancelled take: its later segment and `complete` are 409 `bad_state`, no pipeline) else 409 `bad_state`; a repeat is idempotent; a segment write still in flight is refused and its file removed right after it lands (recorded segments stay for a restore); the purger then removes audio, speech and rows (`memo.purged`) |
| `POST /memos/:id/restore` | 200 memo, `deletedAt` cleared; 409 when not deleted; 404 once purged |
| `GET /memos/:id/result?wait=<s>` | 200 once result-ready (`notified`, `failed`, or an old `needs_route` row), else 202 after the wait (0..600, default 0) |
| `GET /threads?limit&cursor` | `{items: Thread[], nextCursor}`, newest `updatedAt` first; `Thread = {id, kind, title, createdAt, updatedAt, lastMemoId}` (`kind` is `hermes` for every new thread, `chat` only on old rows) |
| `GET /threads/:id` | `{thread, memos (oldest first), messages: [{memoId, role: user\|assistant, content, createdAt}]}`: the conversation is built from the memos' transcripts and replies (Iris's own record, no Hermes read); 404 unknown |
| `POST /devices/register` `{name, platform: ios\|macos, apnsToken?, apnsEnv?, pushToStartToken?}` | 200 `{device, name, platform, apnsEnv, hasApnsToken, hasPushToStartToken, registeredAt}`; upsert by the authenticated device |
| `POST /telemetry` `{resource, spans, logs, dropped}` (the Swift `TelemetryBatch`) | 202 `{accepted: {spans, logs}}`; exported in the background as OTLP with `service.name=iris-ios\|iris-macos`, the memo trace id kept; 413 over 256 KiB, 400 over 500 spans+logs, a schema violation or a bad timestamp |
| `PUT /memos/:id/activity-token` `{token}` (hex) | 204, replaces the stored token; 404 unknown memo |
| `GET /memos/:id/audio` | `audio/mp4`, concatenated on first request and cached; `Range` → 206 / 416; 404; 409 while `receiving` or soft-deleted |
| `GET /memos/:id/assets/:assetId` | a rendered Mermaid file of the reply (ids in the memo's `replyBlocks`): `image/svg+xml` (CSP `default-src 'none'`) or `image/png`, immutable cache; 404 unknown memo or asset; 409 when soft-deleted |
| `GET /memos/:id/speech` | `audio/mpeg` TTS of the speech-ready variant (`speechVariant`: cleaned reply, or `summary.spoken` + "details on screen" past 600 chars; else `summary.spoken`), cached; 404; 409 with neither or when soft-deleted; 503 without the audio door (`AUDIO_DOOR_URL` + `AUDIO_DOOR_TOKEN`) |
| `GET /stats?days=<n>` | `{days, from, to, perDay, perWeek, stepMedians (per step and kind, with n), costPerKind}` over the last `n` local days (default 30, 1..365 else 400); read-only SQL/JS aggregates, `null` kind = mode `transcribe`, no ```iris block, or an old memo |
| `GET /events` | SSE: `ready`, `memo.updated` per state change (and per flag change, delete or restore, without `memo.done`), plus `memo.done` when result-ready, `: keepalive` every 15 s |

Codes: not_found 404, conflict / bad_state / destination_unavailable 409, missing_segments 422, too_large 413, bad_request 400, unavailable 503.
Wire JSON is camelCase.
States: `receiving → received → transcribed → acted → summarized → notified`, with `failed(step)` as a side state. `routed` and
`needs_route` are only read (old rows); the migration moved every open one on.


## Device (the paired iPhone)

`lockf -t 1800 /tmp/iris-apple.lock make device` builds, signs, installs, launches Iris and screenshots the phone to `.artifacts/device-<time>.png`
(`device-build`, `device-run`, `device-screenshot` run alone; `make device-run ARGS="-flag"` passes launch arguments). Scripts: `scripts/device-*.sh`;
the phone (`devicectl list devices`, the connected physical iOS device) resolves at runtime, nothing about it is tracked. Overrides: `IRIS_DEVICE_ID`,
`TEAM=<id>`, `DEVICE_SIGNING=paid|personal`. The phone's tunnel may read `disconnected` while it is `available`: the scripts accept that (it comes up on first use), only `unavailable` is skipped.
- **Signing is one switch, paid by default.** `DEVICE_SIGNING=paid` signs with the paid team, headless: `scripts/device-build.sh` reads `team-id`,
  `asc-key-id`, `asc-issuer-id` and `asc-key-p8` from `op://mini/apple-developer` with `secrets-run read` (never `op`), and passes
  `-allowProvisioningUpdates -authenticationKeyPath <file> -authenticationKeyID <id> -authenticationKeyIssuerID <issuer>` plus `DEVELOPMENT_TEAM=<team-id>`
  to `xcodebuild`. The entitlements apply exactly as tracked (`aps-environment`, the App Group, the Keychain group).
- **The App Group is on for paid builds** (verified 2026-11-05, iPhone 15): `group.com.jkrumm.iris` is registered in the developer portal and enabled on
  `com.jkrumm.iris`, `.widgets` and `.notifications` (Push only on `com.jkrumm.iris`), so `make device` signs all three targets with
  `com.apple.security.application-groups` and `aps-environment` (app) and `codesign -d --entitlements -` shows the group on the `.app` and both `.appex`.
  The app logs `widget.container` (`available`, once at launch) and `widget.snapshot` (`saved`, `cleared`, `phase`, memo id; never the headline) through
  `LoggedLastMemoSnapshotStore`, so a device run proves the container and every `last-memo.json` write. A build failing with "Provisioning profile …
  doesn't match the entitlements file's value for the com.apple.security.application-groups entitlement" means the group is missing in the portal or on one
  of the App IDs (the ASC API key cannot create or attach it: owner step, portal > Identifiers > App Groups). The file itself sits at the container root,
  outside what `devicectl copy from` may read (`Library`, `Documents`, `tmp` only): read the log line, not the file.
  `make testflight UPLOAD=0` with the tracked entitlements signs with Apple Distribution, `aps-environment` production and the group on the app and both extensions (verified 2026-11-05).
- **The key file's life:** 1Password flattened the `.p8` newlines into spaces, so `pem_normalize` (`scripts/device-lib.sh`, the same rule as
  `normalizePem` in `server/src/notify/select.ts`) rebuilds real newlines and 64-character body lines into a `mktemp` file with mode 0600; a `trap` on
  `EXIT` deletes it on every exit path. Only the path, key id and issuer id are in argv; the key is in no log and no tracked file.
- **Personal Team is the fallback** (`DEVICE_SIGNING=personal`): the free team Xcode knows (`defaults export com.apple.dt.Xcode`), no key file. It signs
  neither Push nor App Groups, so the three `CODE_SIGN_ENTITLEMENTS` variables (`IRIS_APP_ENTITLEMENTS` etc. in `apple/project.yml`, default the tracked
  files, so the simulator/CI build with `CODE_SIGNING_ALLOWED=NO` is unchanged) point at copies without `aps-environment` and the App Group, derived at
  build time (`entitlement_settings`), so nothing drifts. Limits: 7-day profiles, 10 App IDs per 7 days (`com.jkrumm.iris`, `.widgets`,
  `.notifications` are three; never rename them), 3 devices, no APNs token and no remote Live Activity.
- **APNs on the phone:** `PushRegistrar` (apple/Iris, `PushAppDelegate` forwards the callbacks) registers once a connection is saved and sends the hex token
  with `apnsEnv` through `devices/register`: `sandbox` on a Debug build (`#if DEBUG`, what `make device` installs), `production` on Release (TestFlight).
  Details: TDD §4 Notifications. Only the Iris iOS targets are built by `make device`; `IrisMac` and the test bundles are not.
- **First install:** the first `-allowProvisioningUpdates` build registers the device; the owner must trust the developer once on the phone (Settings >
  General > VPN & Device Management) or `launch` fails with "invalid code signature ... profile has not been explicitly trusted".
  A codesign keychain prompt on the mini's screen needs "Always Allow" (not seen so far: the build signed headless).
- **Screenshot:** `xcrun devicectl device capture screenshot` (Xcode 27). `pymobiledevice3` does not work here: the phone is on a CoreDevice network tunnel,
  `usbmux list` is empty and an RSD tunnel needs root.
- **Connecting the app** has no launch-argument route (no production backdoor): the owner types the server URL and the `iphone` device token once in
  Settings > Connection (Keychain item survives reinstalls over the same bundle id). The tailnet VPN must be on. The phone must be unlocked for `launch`.
  Verified 2026-10-30: a typed memo from the phone reached `done`. Known app gap: Settings says "Connected" for any saved configuration, reachable or not.
- **Device observability (TDD §8):** every capture, route, interruption, outbox, intent and Live Activity event is `DeviceLog.shared.event(...)` (apple/Iris) or
  an `IrisCapture` `CaptureEvents` call: one `os.Logger` line in `com.jkrumm.iris` and one relayed record (`service.name=iris-ios`, trace id = the memo id
  without dashes, ordered by `seq`). Add an event there, not a bare `Logger` call, and never a token, transcript, reply or port uid in one. `service.version` is the
  `IRIS_BUILD_SHA` build setting (`scripts/device-build.sh` passes the short git sha; any other build reports `dev`). The widget extension only logs to the console.
  Delivery is single-flight and bounded (a send ends at 20 s, the background flush holds its assertion at most 20 s), a crash file that cannot be read before the
  first unlock costs nothing (records wait in memory), and records left behind for another server are counted in `dropped` (TDD §8).
  Headless read of a take: skills `device` and `memo-debug`.

## Validate

| Target | Runs | Where |
|-|-|-|
| `make check` | `check-server` (oxlint, `oxfmt --check`, `tsc --noEmit`, `bun test`), `check-contracts`, `check-strings`, `guard`, and `check-apple` wherever `xcodebuild` exists | mini, CI (`check.yml`, no Apple on Linux) |
| `make e2e` | the pipeline against a fake-booted server (needs ffmpeg) | mini, CI after `check` |
| `make check-apple` | Theme drift, `check-strings`, `swift format lint --strict`, `swift test` per package (macOS host), `xcodebuild build` of `Iris` + extensions (simulator) and `IrisMac`, then `IrisMacTests` (hosted in the Mac app, `-IrisFakeData`: notifier, composition root, detail model) | mini, CI (`apple.yml`) |
| `make snapshots` | IrisUI snapshot tests on the pinned simulator (`RECORD=1` re-records) | mini, `apple.yml` |
| `make uitest` | XCUITest flows (`-IrisFakeCapture`); `ONLY=<Class>[/<test>]` runs one class or method (`-only-testing:IrisUITests/…`) | full suite: `apple.yml`; mini: `ONLY=` only |
| `make device` | `device-build` + `device-run`: signed Debug build, install, launch and a phone screenshot on the paired iPhone (see Device) | mini, phone wired |
| `make testflight [UPLOAD=0\|1]` | `scripts/testflight.sh`: archive `Iris` Release, export a signed `.ipa` into `.artifacts/testflight/export` (`UPLOAD=0`, default) or export-and-upload (`UPLOAD=1`, needs the App Store Connect app record); `CFBundleVersion` = `<git rev-list --count HEAD>.<UTC epoch hours>` (strictly increasing, so a same-sha weekly rebuild uploads) | mini, under the Apple lock; the poller's release hook runs it |
| `make check-strings` | the String catalogs: `de` on every key, no stale key, no hard-coded user-facing literal (bun only, runs on Linux CI too) | mini, CI, `check`/`check-apple` |
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
`/devices/register`, `/activity-token`, `/audio` (Range 206), `/speech` (audio/mpeg) and the threads flow (a hermes memo, a reply into its thread
with `send-memo.ts --thread`, then `/threads` and `/threads/:id` with both turns); every memo must reach `notified` with the fake Hermes's `kind` and `actions` and the fake summarizer's `summary`. The server is always killed.

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
does, and prints transcript, reply, `kind`, `actions`, summary, step timings and cost. Env: `IRIS_URL` (default
`http://127.0.0.1:7730`), `IRIS_TOKEN` (required); flags `--url --token --mode hermes|transcribe|auto|chat|journal|tab
--wait <s>` (default `hermes`). Exit 0 `notified`, 1 `failed`, 2 timeout, `needs_route` (an old row) or usage error. Its tests
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
  Rotate it by editing that file and restarting both LaunchAgents. `APNS_*` comes from the team-wide `op://mini/apple-developer/*` item (in `.env.mini.tpl`, seeded via `headless.refs`; `APNS_TOPIC` is the bundle id), so the APNs notifier runs; the `.p8` field holds the PEM on one line and `normalizePem` (`notify/select.ts`) rebuilds it.
- **Release hooks** (Wave 22): after a deployed tick, and on every tick whose SHA is already deployed, the poller runs `scripts/release-hooks.sh <sha>` (executed, not sourced; `release_hooks` in `mini-deploy.sh` is the only poller code). It starts, per hook, a **detached** job (own session, `jobrun com.jkrumm.iris-release-<hook> --lock iris-release-<hook> --timeout 4800`, output `~/Library/Logs/iris-release-<hook>.log`) that checks the exact SHA out into `~/.iris/release-src/<hook>` (a worktree: the poller's `git reset --hard` never moves sources under an archive) and runs the make target under `lockf -t 1800 /tmp/iris-apple.lock nice -n 10 timeout 2400`. The poller itself stays fast.
  Hooks: `testflight` (`make testflight UPLOAD=1`, marker `~/.iris/testflight-sha`) and `mac` (`make mac-release`, marker `~/.iris/mac-release-sha`, skipped while the Makefile has no such target). Each is **off** unless the untracked `~/.iris/release.env` has `TESTFLIGHT=1` / `MAC_RELEASE=1` (read line by line, never sourced; absent = off, logged as `skipped` every tick). A hook runs when `apple/**` changed since its marker's SHA, when there is no usable marker, or when the marker is older than 7 days (TestFlight builds expire after 90 days). The marker is written only after the make target succeeded; a failure writes `~/.iris/<hook>-failed` and holds that hook off for an hour. `DRY_RUN=1 scripts/release-hooks.sh <sha>` prints what would start and changes nothing (`RELEASE_HOME` / `APP_DIR` override the paths). Turn `TESTFLIGHT=1` on only once the App Store Connect app record exists.
- `HERMES_URL` is composed in `launch.sh` from `HERMES_HOST` + `HERMES_PORT`. Hermes is the only destination: no brain checkout or herdr is left in this server. The agent-workflows host (`AGW_URL`) serves `triage` only, behind `summarize`; the audio door is agent-workflows' `audio` process.
- agent-workflows host calls (`POST /triage`, synchronous) carry `x-agw-purpose: iris`, `x-agw-caller: iris` and `x-agw-project: iris` (constants in `agw-client.ts`; the run record and the ledger book the spend as caller `iris`, project `iris`; a malformed value is a host 400) and `Authorization: Bearer <AGW_API_SECRET>`; `AGW_API_SECRET` is `op://mini/agent-workflows/API_SECRET` in `.env.local.tpl` (in `headless.refs`). Every answer, errors included, has `agw-run-id`, logged and set on the span as `agw.run_id`. 400, 401 and 502 `INVALID_OUTPUT` are final (any other 502 is transient); 500, 503 and network errors are transient (the runner's retries); the step error carries status, host code and run id, never the body (`agw.error_body` logs the code and the body length, `agw.response_unreadable` the parser message); a 5xx whose body stalls past the guard is a hang guard failure; the hang guard (30 min) aborts the request and is not transient. `costUsd` null is stored as null, never 0. `make verify` also probes `GET http://127.0.0.1:7791/health`.

## Verify & Monitor

- `make verify` — exit 0 iff `GET /health` answers `status: ok` (public; `{status, degraded[], inflight}`) and the audio door's
  `GET http://127.0.0.1:7792/health` and the agent-workflows host's `GET http://127.0.0.1:7791/health` do too (the downstream check).
  `degraded` lists `otel`, `device-tokens` and steps without a downstream (`transcribe`, `act` (no `HERMES_*`), `summarize` (no `AGW_*`), `speech`).
- `make smoke` — a real German 96 s recording (`fixtures/audio/de-90s.m4a`) through the pipeline to
  `notified` in the default mode (`hermes`). `IRIS_URL=https://iris.mini.<domain> make smoke` goes through the tailnet door. Uses the
  `smoke` device token; the memo shows up in a Hermes session named by the memo id. It prints the memo's `kind` and `actions`: no `kind` means the reply had no valid ```iris block (`hermes.meta_invalid` in `make logs`).
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
- **Step results live on the memo row** (`audio_seconds`, `transcript`, `destination_ref`,
  `reply_text`, `summary_json`, `kind`, `hermes_headline`, `actions_json`; `route` is only on old rows), written by `MemoStore.completeStep` in one transaction with the state
  change and the done row; a lost compare-and-set writes nothing. `resetForRetry` clears the columns of
  the re-run steps and later. A store error in `completeStep` is bookkeeping, not a step failure: it
  propagates and the drive failure is logged.
- **Downstream env** (all optional, empty = unset): `AUDIO_DOOR_URL` (https or a loopback host, else the start fails) + `AUDIO_DOOR_TOKEN` (both, for `transcribe` and `speech`) and `HERMES_URL` +
  `HERMES_TOKEN` (both, for `act`), `AGW_URL` (https or a loopback host) + `AGW_API_SECRET` (both, for `summarize`). Without the first pair `/health` lists `transcribe` and `speech` in `degraded`; without the second `act`: a memo then waits at `transcribed` until Hermes is configured and the server restarts; without the third `summarize`, which never parks a memo: the step fails and is skipped (**Summarize is optional**). `speech` answers 503 `unavailable`.
- **Hermes decides** (TDD §3 "Hermes decides"; supersedes the routing, answering-a-park and chat-mode design of Waves 3-17, kept only as the TDD's "Retired 2026-11-04" paragraph): Iris no longer classifies. Every mode but `transcribe` runs `transcribe → act → summarize → notify`
  (typed: `act → summarize → notify`); `act` hands the transcript to Hermes, which decides what the memo is and acts with its own skills. Every turn, a new session or a `threadId` continuation, carries the `system_message` `IRIS_SYSTEM_MESSAGE`
  (`adapters/hermes.ts`; the turn comes from Iris, load `skill_view('iris')`, end the reply with one ```iris block) plus, for the legacy modes `chat` / `journal` / `tab`, the line `The owner picked: Chat.` / `Journal.` / `Tab.`
  (`auto` and `hermes` add nothing; the mode is stored as received). The session `source` is `iris`. The block is `{kind, headline}` (no `spoken`: the spoken line and the summary are agw `triage`'s): the **last** ```iris fence of the final reply is parsed with zod (extra keys, an old `spoken` included, ignored; no fence, bad JSON or a missing key = no block, logged
  `hermes.meta_invalid` with the reason, never the content) and cut out of `reply_text` either way. `kind` (trimmed, lower-case, 24 code points) is the memo's `kind` column; `headline` (60 code points) is the `hermes_headline` column, never on the wire and never the memo's `summary`. `notify` announces `summary.headline ?? hermes_headline ??` the transcript clipped to 60; `kind` is null without a block. `actions` are the tools of the turn from the session stream's `tool.started` frames (field `tool_name`; for `skill_view` the loaded skill's name from `args.name`, plugin prefix and path cut, and nothing for the `iris` skill that opens every turn or a call without a usable name),
  deduplicated in first-seen order, ≤ 12, names only, never other arguments. `kind`, `hermes_headline` and `actions` are written by `completeStep` of `act` (the summary by `summarize`); a retry from `act` clears them and the summary. Memos whose `route` is set (before 2026-11-04) keep rendering from their rows; `stepsOf(mode)` is the pipeline for them too, so a
  `failed(route)` memo retries from `act` (delivers to Hermes whatever its old route was). Migration 14 turned every open `needs_route` memo into `failed(act)` ("parked before routing moved to Hermes"; Retry from Act delivers it) and moved `routed` back to `transcribed` (`summarized` is a live state again);
  `route_decisions` stays as history and is never written. Hermes is the only destination, so the herdr, herdr-core, journal and decider code, agw `decide` and their env (`HERDR_SOCKET`, `HC_*`, `BRAIN_DIR`) are gone; the `iris` skill in hermes-agent owns what they did.
- **Summarize is optional** (`OPTIONAL_STEPS` in `memo/memo.ts`): `summarize` runs agw `triage` on the transcript and the final reply (the ```iris block already cut), never tool traffic, with `destination` always `hermes`. When it fails for good (after the runner's automatic retries; a triage error, a 402, no summarizer), `runner.runStep` calls `store.skipStep`: the step row stays `failed` (error and attempts kept), the memo moves `acted` → `summarized` (not `failed`), `notify` runs and the memo ends `notified` with `summary` null, a `step.skipped` log line and a `memo.updated` (step `summarize`). Every other step still fails the memo. `POST /retry {from: "summarize"}` also works on such a `notified` memo (`resetForRetry`: `notified` with a failed `summarize` row), resets it to `acted`, re-runs summarize and notify. `/speech` on a reply with no summary speaks the clipped cleaned reply (`speechVariant`), no 409. History and `memo.summary` null: clients show the transcript. `repairFailedSummaries` (Wave 16's boot repair for `failed(summarize)` rows) is gone: the step can no longer fail a memo, and the one-off ran on the production database.
- **Threads** (TDD §3 act, data model): every Hermes session is a thread (`threads.kind` `hermes`; old `chat` rows stay). The Hermes adapter names it in `Delivery.thread` (`{id, kind, title}`, id = session id = `destination_ref`); `act` persists it
  (`patch.thread`: `completeStep` upserts the `threads` row and sets the `act`-owned `memos.thread_id`). The memo wire carries `threadId`, omitted when null.
  Continuing a thread: `threadId` on either create route (404 unknown thread, 409 `destination_unavailable` while Hermes is not configured, 409 on a replay naming another; `continuedThread` in `memo.ts` tells a continuation from a memo's own
  session, whose id is the memo id), `deliver({threadId})` talks into the existing session. Turns into one thread run one at a time (`memo/keyed-queue.ts` in the `act` handler; the second waits, at most 30 min: then `act` fails "thread <id> is busy" naming the memo ahead and its task never runs, the line stays ordered; a waiter parked there releases its `driveAll` slot through the handler's `whileWaiting` and takes one again when its turn comes). `/threads/:id`
  builds its conversation from the thread's memos (transcript = user, `reply_text` = assistant), never from Hermes. Swift: `MemoMode` decodes an unknown value to `.unknown`.
- **Mode `transcribe`** (TDD §3 state machine): the pipeline is `transcribe` → `notify` (`memo.ts` `stepsOf(mode)`; `nextStep`, `advance` and `stateBefore` take the mode), the memo ends
  `notified` with the transcript and NULL `kind`, `reply_text` and `summary`, with no act row on the timeline; the alert headline is the
  transcript's start. A typed memo in this mode runs `notify` only; `threadId` with it is 400; `POST /retry` from a step the mode lacks is 400. Swift: `MemoMode.transcribe`, offered by
  `MemoMode.voiceModes` (and, as a typed memo, the composer); `PipelineSteps.applicable(to:)` gives such a memo two steps.
- **`act` is at-least-once:** a crash or restart mid-`act` replays the step, which posts a second turn
  into the same Hermes session (and, if the first turn already acted, repeats its side effect). Shutdown keeps the window small: `app.stop(true)`, `runner.stop()` (the
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
- **Schemas** in `http/schemas.ts` are the contract source: routes use them for `body` / `query` / `params` / `response`,
  and `schemas.test.ts` fails if a Transform sneaks in (the two `t.Numeric` query params are the exception). Elysia's
  own `t.Integer` is a Transform, so integers are `t.Number({multipleOf: 1})`.
- **APNs** (`APNS_KEY_P8` PEM, literal `\n` or spaces for newlines allowed, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` = bundle id): the
  APNs notifier runs only when all four are set (else the log notifier), and that is deliberately not in `degraded` (the log
  notifier is the intended state until enrolment; a degraded `/health` fails `make verify`). Boot logs `notifier.selected`.
  Environment per push is `device.apnsEnv`, `sandbox` when null; with a null `apnsEnv`
  a BadDeviceToken (likely a production token sent to the sandbox) is logged with a hint and the token is kept, so only
  an explicitly registered env makes BadDeviceToken clear it (410 / Unregistered always do, via the conditional `clearApnsToken`). `notify` sends one push per memo: the Live Activity `end` when the memo has an
  activity token (it carries `aps.alert` {kind chip or "Iris", headline, `sound: "default"`}, so the device lights up and plays the sound; no separate banner, owner 2026-11-05, TDD §3 notify), else the alert push
  (if the device has an `apnsToken`; also the fallback when the `end` is refused for good); neither registered logs `notify.no_token` and succeeds. A transient `end` failure throws without sending the alert.
  A rejected token never fails the memo: `notify.apns_rejected` is logged, and BadDeviceToken / 410 Unregistered clear the
  stored token (only if it is still the one we sent to); other 4xx (e.g. 403 InvalidProviderToken) are logged, tokens kept.
  Transient failures (status 0, 408, 429, 5xx, 403 ExpiredProviderToken) throw a `TransientError`, so the runner retries notify twice (2 s, 8 s) and then fails it for `POST /retry`
  (a retry re-sends the push by the same rule; the alert carries `apns-collapse-id` = memo id, so a re-send replaces the banner instead of duplicating it). `phase` (Live Activity `update`, priority 5) is bound to memo events by
  `bindPhaseUpdates`: not for `receiving` or `notified`, serialised per memo, latest state wins, errors logged only.
  The alert carries `category: MEMO_DONE` only (the `MEMO_NEEDS_ROUTE` alert and `notifier.needsRoute` are gone with the park).
- **APNs transport:** node-apn builds the ES256 JWT with `jsonwebtoken` and regenerates it when its `iat` is 3300 s (55 min)
  old, checked per request (Apple: not <20, not >60 min); it retries 408/429/5xx and ExpiredProviderToken 3x. We cap in-flight
  streams at 10 (Bun ignores `peerMaxConcurrentStreams`) and send the first request per environment alone (Apple allows one
  stream until a valid token lands; a status-0 failure re-arms that). `config.port` (443) is passed to `http2.connect` and Bun
  honours it over the URL, so a test server needs `address` and `port` both. Not verified: real Apple hosts and GOAWAY JSON.
  node-apn emits a harmless `MaxListenersExceededWarning` (one `timeout` listener per stream on the session) above 10 streams.
- **Live Activity contract (Swift side):** payload `aps` is `{timestamp, event, "content-state"}` (+ `dismissal-date` and `alert` {title, body, sound} on `end`,
  now + 15 min; the `end` is the memo's announcement). `ContentState` is plain camelCase Codable: `phase` (`processing` | `done` | `failed` on the wire),
  `routeChip?` (the memo's `kind`, capitalised), `headline?` (≤ 60), `hasReply`. `inputName` is never sent: the client keeps it device-side and must declare it
  optional. Alerts carry the kind chip (title, "Iris" without a kind) + headline only (never transcript or reply), `category: MEMO_DONE`, `thread-id: memo`, `mutable-content: 1` and a top-level `memo` id.
- **Bookkeeping failures** (`completeStep` throws after a handler ran) log `runner.bookkeeping_failed`
  and propagate; the step row stays `running` and the memo keeps its state until the next `driveAll`.
- A stored `summary_json` that fails the zod `Summary` schema reads as `null` with a `memo.summary_invalid` log.
- **SSE** has no `Last-Event-ID` replay; clients refetch the list on reconnect.
- **Long polls and SSE** call `server.timeout(request, 0)` to escape Bun's idle timeout.
- **Secrets on the mini:** `secrets-run`, never `op`.
- `server/package.json` is imported by `telemetry/otel.ts` for `service.version`; keep it there.
- **Apple build artifacts:** `xcodebuild` leaves `apple/.dd.noindex` and per-package `.dd.noindex` / `.build`, and `make screenshot` writes `.artifacts/`; all gitignored.
  `Iris.xcodeproj` is generated: edit `apple/project.yml`, never the project.
- **Segment files** (Wave 18 I2): `SegmentWriter` writes each segment as a fragmented m4a (`AVAssetWriter`, `movieFragmentInterval` 0.5 s, AAC 16 kHz mono 32 kbps; the name `<memo>-<index>.m4a` and `audio/mp4` are unchanged), never an `AVAudioFile`, whose m4a has no index until it is closed and is unreadable after a kill. A force-quit leaves a file that plays up to its last whole fragment (all but about 0.5 s), and the startup sweep adopts it as the take's next segment through the existing rules; one that does not play (killed before the first fragment) is set aside, never deleted. The recorder hands a closing writer to a chain and starts the next segment at once; a segment is queued only after `finishWriting` and a read-back, and `stop()` waits for the chain before `.stopped`. A file that ends where the encoder stopped is queued with the duration it really holds and the take fails; one that does not read back is left on disk and fails the take; after either, no later segment of the take is queued (`SegmentCloser`), so the outbox never waits for a missing index, and the later files stay for the sweep. A backlog the encoder was not ready for is retried every 20 ms while the segment is open. A take killed in its first segment keeps its outbox item, hidden, until the sweep has looked for its index 0 (`OutboxStateMachine.adopt`, `settleEmptyRecoveries`): a playable file is adopted, otherwise the empty take is dropped and the file set aside; a directory that cannot be listed, a set-aside queue that cannot be read or one that names a file settles no empty take (it stays hidden until a sweep has looked). A writer that cannot be created, a buffer that cannot be built or an append the input refuses is reported by that segment's close, in order, like a failed finish; `SegmentWriter.finish` sets a `finished` flag with `markAsFinished` under its lock, so the retry task never appends to a finished input. `docs/research/2026-10-30-avaudiofile-kill.md`.
- **Capture and outbox** (Wave 15 I3, TDD §4): `IrisCapture` holds `CaptureSession` (one take: session, route, recorder, outbox) and the persistent `Outbox`, a queue of whole items
  (typed memo, chat message, voice take, thread reply) with `create` → segments → `complete`, idempotent by memo id, jittered bounded backoff, stall after 10 failures or a 4xx a retry cannot fix, "retry now" and "discard". The app reaches it through
  `OutboxService` (a lazy `CaptureStack`; `APIOutboxUploader` is the `SegmentUploader` over `APIClient`); the composer, the thread's `OutboxVoiceReplyCapture`, the Settings queue and `StartMemoIntent` (`Iris/Intents/`, compiled into the widget too) all go through it.
  A take is created on the server at its first segment, so a cancelled take leaves nothing behind. An outbox file that cannot be decoded is never emptied: Settings "Reset outbox" renames it to `outbox.quarantined-<UTC timestamp>.json` (kept, shareable from Diagnostics, its segment files untouched) and opens a fresh queue (`-IrisFakeUnreadableOutbox` shows it on fakes). A startup sweep (`Outbox.sweepOrphans(using:)` over the `SegmentFileStore` port) of the capture directory adopts segment files no record names into the take they belong to (the next index too for a finished take whose `complete` was never handed out, `OutboxMemo.completeMayHaveLanded`) or moves them to `capture/quarantine/`; nothing is deleted, and Settings shows what is kept (count, size, a share of the list; past 50 files or 200 MB a note, never an automatic delete). A file the sweep cannot move stays put, is retried at the next launch and is listed in Settings (`SweepReport.stuck`, `Outbox.strayFiles()`). A second Reset tap mid-reset joins the first. `Outbox.resume()` saves the dispatched state before it starts a transfer. A failed take whose recorder cannot be stopped is finished without the user: with its tail when the recorder queued one, else after the grace period (the user's stop leaves the finish to the pump, so a queued tail is never overtaken, even with nothing closed yet; the stop keeps its count and failure until it returns). The audio session stays active until every recorder stop has returned and the take is over: `stop()` and `cancel()` deactivate it then, behind the take gate. A take that failed on its own is not deactivated by the failure (`failTake` stops the recorder, which releases the microphone, and `TakeState.recorderReleased` says so); its session is deactivated by the user's Stop or Discard. Whether a still-active session of a failed take disturbs spoken-reply playback is unverified on the device. `complete` answered 422 `missing_segments` sends the listed segments again (`MissingSegmentsError`) instead of stalling. `OutboxMemo.completeMayHaveLanded` is always written; a queue file from before it reads "may have landed" unless its create or a segment is still open (no tail grows a completed take). `CaptureSession.stop()` / `cancel()` wait at most 10 s for `recorder.stop()` and for the recorder's last event (then the take ends with what closed and `TakeResult.failure`, or throws `recordingFailed`); a stop that timed out leaves the memo open for the tail segment and the `stopped` event (finished after a second 10 s with what closed if it never comes), so the tail is uploaded; a `recorder.stop()` that never returns refuses the next `start` until it does; `TakeController.start` is single-flight and its `cancel()` throws when the session cannot be opened. `start` / `stop` / `cancel` of a take are serialised (a gate in `CaptureSession`); `CaptureStack` never falls back to an in-memory queue (an unreadable or undecodable store refuses new items, is left untouched and is retried; an item whose write fails is refused too); Settings hides Discard on a row that is still recording, and the Live Activity follower ends the activity on a stall or discard, not on a retryable failure; `endOrphans()` (also run on a connection change) spares the takes this process is driving, and `ActivityTokenRegistrar` keeps one `PUT` per memo in flight so an older token never lands after a newer one (the gate is per memo id, so it survives `finish` + `begin` of the same memo). `JSONFileOutboxStore(segmentDirectory:)` saves each segment by file name and resolves it against the current capture directory on load (an install over the app gives the data container a new path, which stalled every segment of the first device take as "the recording file is gone"); old absolute paths are healed and a segment stalled on one is retried once. `APIOutboxUploader` answers a segment `PUT`'s 409 `bad_state` (the memo left `receiving`) by asking the server what it holds: the index is below its `segmentCount` → delivered; otherwise the file is the only copy and is set aside (`keeping`, the sweep's `quarantine/`), never deleted. A create that was on the wire at a kill is re-sent after relaunch, and a discard before that deletes the memo (the dispatch is saved before the request goes out). `LiveActivityPhase` has the client-only `recording` / `paused` / `uploading` (the wire and fixtures keep four). The Record control runs `OpenRecorderIntent: OpenIntent` (`authenticationPolicy = .requiresAuthentication`, compiled into app and widget): a control's plain intent runs in the extension, which cannot record, and a Lock Screen button is inactive until unlock, so the press asks for the unlock, opens the app and starts the take in the foreground; a failed start is `TakeModel.failure` and thrown. `StartMemoIntent` (`AudioRecordingIntent, LiveActivityIntent`, background start) is for Siri and Shortcuts. A pause keeps the engine running and drops the samples (the island's Resume runs with the app in the background, where starting an engine is refused: `!rec`). Without a push token (Personal Team) a handed-over Live Activity is ended by the app (`StaleActivityRule` / `StaleActivitySweeper` in `TakeLiveActivity.swift`: polled while the app is on screen, ended with `ActivityDismissal.soon` (the system removes it) when the app goes to the background or the hand-over happens there, swept at launch and foreground, displaced by a starting take; older than 30 min always ends). An activity remembers its server (`MemoAttributes.serverKey`, a digest of the URL): after a server-URL switch the new server's 404 does not end it (it is not asked about; only age ends it). The launch sweep asks about all activities at once, is single-flight, is repeated on foregrounding (a follower does not poll while suspended), and every end is logged with its reason. Outbox work is bound to the server it was queued for (Wave 19 I1): `OutboxItem.serverKey` / `OutboxDeletion.serverKey` are stamped from `CaptureStack.Parts.serverKey` when the item is queued, the state machine hands out nothing bound to another server (it waits, visible, and resumes when that server is configured again), `ReconfigurableAPIClient` checks `OutboxTransfer.serverKey` at the moment it picks its target (`WrongServerError` = back to pending, no attempt), and `HistoryModel` (`serverKey`) drops pages, refreshes and created memos of a server it has left; a DELETE's settle and its hide reach History in either order. `SegmentCloser` bounds `finishWriting` (30 s; a hung finish fails that close in order and leaves the file for the sweep), `cancel()` removes the capture directory's files of the memo (`SegmentFileStore.discardFiles(of:)`), and a take that failed on its own releases `captureActive` once its recorder stop returned (`TakeState.recorderReleased`). Device-only: Control press, background take, Bluetooth, Live Activity rendering.
- **Widgets** (Wave 19 R2, TDD §4 "Widgets"): `IrisWidgets/HomeWidgets.swift` (`RecordWidget`, `LastMemoWidget`, `StaticConfiguration`, timeline policy `.never`) over IrisUI's `Widgets/` (`LastMemoSnapshot`, `FileLastMemoSnapshotStore`, `LastMemoWidgetFeed`, `LastMemoWidgetView`, `RecordWidgetView`; views are plain values, no WidgetKit environment). The only data is `last-memo.json` in the App Group container (state, route chip, headline ≤ 60, `memoID`, dates; never transcript, reply, park reason or error): the app writes it through `LastMemoWidgetFeed.observe` / `forget` and reloads `IrisWidgetKind.lastMemo`, the extension reads it (wired in `Iris/LastMemoWidgetFeed+Memo.swift`: `HistoryModel.onMemoObserved` / `onMemoForgotten` → `attach(to:)`, behind History's server guards; a connection switch calls `reset()`; fakes use the in-memory store). No App Group (Personal Team, unsigned build): `containerURL` is `nil`, the store is unavailable, the widget draws "Open Iris". The new widget code names no `IrisCore` type (no network, no token). Record is `Button(intent: OpenRecorderIntent())`, the control's intent (device row W-1). An in-flight snapshot older than 30 min reads `idle`. New widget strings go in IrisUI's catalog; snapshot references are `WidgetSnapshotTests` (English and German, pinned `locale`).
- **App composition:** `-IrisFakeCapture` (every UI test, `make run-sim`) runs the fake API, silent media and fake capture (the real outbox on fake audio; `-IrisFakeOffline` fails the first create of each kind); without it the app is
  production: server URL + device token from Settings → Connection (token in the Keychain, URL in `UserDefaults`), one `ReconfigurableAPIClient`
  shared by every model. Nothing saved: the app opens on Settings and loads nothing. Memo audio and speech are downloaded with the bearer header by
  `MediaDownloader.shared` (one `URLSession`, single-flight per URL, `evict(memoID:)` when History deletes or hides a memo (the cache check runs on the same actor as eviction, and a launch sweep removes cached files untouched for 14 days): it returns at once, scans off the main actor and cancels that memo's downloads still on the wire, so none lands afterwards) and played from the file (no `AVURLAssetHTTPHeaderFieldsKey`, TDD §4 "Authenticated media"). `ReplyImageStore` loads at most three files at once. `MemoPlayer` follows a periodic time
  observer; call `teardown()` when the screen goes away. The unsigned simulator build (`CODE_SIGNING_ALLOWED=NO`) has no Keychain (`-34018`): the
  Keychain round-trip unit test cancels there and is device-verified only. `StatsModel`/`SettingsModel`/`HistoryModel` `load()` drop a stale answer (generation guard). Settings' server row is `ConnectionStatusLine(connection:link:)`: the health probe from when Settings appeared plus `HistoryModel.link` (`ServerLink`: what the event stream and list loads last saw), so a dropped network or Tailscale, or a gateway 502/503/504 without a contract body (a proxy in front of a server that is not answering), reads "Unreachable" with "Server not reachable — is Tailscale on?" and a 401 "Token rejected" instead of a stale "Connected". When the two disagree the newer observation wins (`SettingsModel.probedAt` vs `HistoryModel.linkObservedAt`).
- **Thread view** (`ThreadView` / `ThreadModel`, TDD §4 "Thread view"): a History row of a continued thread pushes it (`Memo.opensThread` = `threadId != nil && threadId != id`: `act` gives every Hermes memo its own session id as `threadId`, and such a memo keeps the plain detail with Retry, waterfall, kind chip and actions; the Mac detail follows the same rule); the model derives turns from
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
  every screen pins it under its navigation bar with `.takeBanner()` (a banner over the whole `TabView` would cover the bar's buttons). The record control is the tab bar's bottom accessory (`RecordRow`: three visible buttons, no hidden gesture: a large Hermes button (`record.start`, the default, `sparkles` because the SF Symbols have no robot glyph), a smaller Transcribe button (`record.transcribe`) and a smaller Text button (`record.text`, opens the composer); `isEnabled:` hides it during a take on iOS 26.1+, disabled on 26.0);
  memo detail and thread hide the tab bar, which does not hide the accessory (Apple DTS, iOS 26.1), so their bottom bars (`DetailActionBar`, `ThreadReplyBar`) register through `.hidesRecordAccessory()` (`RecordAccessoryPresence`, counted, injected by `RootView`) and `isEnabled:` takes the control off while one is shown; on 26.0 it stays (the banner still shows). A take bound to a thread (the thread's hold-to-talk) is not shown by the banner. The Live Activity views are IrisUI's (`LiveActivityPanel`, `Island*`, `ActivityStageDashes`; plain `ActivityPresentation` values, no IrisCore) and the widget maps `ContentState` onto them;
  Stop / mic swap / pause are `LiveActivityIntent`s (`StopMemoIntent`, `SwitchInputIntent`, `PauseMemoIntent`) that call the same `TakeController`. The step progress of a processing memo is the four stages record, upload, process, done from the phase alone (`ContentState` has no step field; per-step progress needs the server to push one). A new take's activity says "N earlier memos are still sending" in `headline` (client phases only).
- **Live preview** (Wave 19 R1, TDD §4 "Live preview"): the take screen shows the on-device transcript as it is spoken (`SpeechTranscriber`, iOS 26), display only: never uploaded, stored, logged or put into telemetry; the server transcript is the truth. `PreviewTap` (IrisCapture) is an additive, bounded, read-only stream of the samples the recorder accepts; `LivePreviewModel` (`TakeModel.preview`) consumes a `LivePreviewEngine` (production `SpeechAnalyzerPreviewEngine`, fake `FakeLivePreviewEngine`) handed to `TakeController` as a `LivePreviewSource` (`nil` = none). Absent language or model (checked at runtime: supported and in `installedLocales`), a failing analyzer, or no source: no preview, the take goes on; the app never starts a model download. The analyzer does not run in the Simulator, so only the fake is tested there; no `NSSpeechRecognitionUsageDescription` (that is `SFSpeechRecognizer`). Never log or store what it hears.
- **Two modes, the kind chip** (Wave 21 A1, TDD §4 "Two modes and the kind chip"; Iris stopped routing, Hermes decides): `MemoMode` is `hermes` (default) and `transcribe`; any other wire value reads as `hermes`. The composer (the record row's Text button, a thread reply, the History [+]) has two send targets, "Send to Hermes" and "Transcribe" (a reply bound to a thread offers Hermes only). A memo's chip is `kindLabel` (`MemoPresentation`): the memo's `kind` capitalised like the server's alert, else an old memo's route name, "Transcript" for mode `transcribe`, "Hermes" while nothing is known; `KindChip` is neutral, `KindPalette` colours the known kinds (a free-form kind is data: `Text(verbatim:)`). The detail shows `actions` as one quiet line under the reply ("Hermes used: capture, terminal"). History filters by kind from the kinds present in the loaded pages (`HistoryFilters`, `?kind=`) plus Favorites, Threads (`thread=true`) and Archived; stats series are per kind (top four by count, `Other`, `Transcript`). An old memo parked at `needs_route` reads "Not delivered" and offers no routing. `SpeechPlayer` is the one spoken-reply player (`Memo.isSpeakable`, notified + a reply + not deleted, is the one rule: the media sources, hence Play and `PlayReplyIntent`, and `SpokenReplies`): the detail's Play,
  `PlayReplyIntent` (an `AudioPlaybackIntent` in `Iris/Intents`, compiled into the widget; the done Live Activity has a Play button, compile-checked only) and spoken replies (Settings toggle, `SpokenReplies`: foreground only, memos this device created, once each; the take sample is taken when `memo.done` arrives, not after the task hop); it never interrupts: while a reply or the open detail's recording plays or any take is open (`TakeModel.isCapturing`) the memo is skipped for good, no queue (Wave 17 I3). The other direction (Wave 18 I1): `TakeController.captureActive` is one synchronous flag, set before a start awaits anything (a thread's hold-to-talk too, `OutboxVoiceReplyCapture.claim`) and cleared only after the session has ended; a start also pauses the reply, the open detail's recording and any speech still downloading (`SpeechPlayer.pauseForTake()`). Every playback start reads the flag at the moment it starts (`SpeechPlayer.captureActive`); nothing resumes by itself. Settings → Microphone edits the active route's mic rule (`MicRulesModel` over `RouteManager`;
  `RouteSnapshot.outputNames` is display only). The fake API's samples carry kinds and actions, one old memo with a route and no kind, and a transcript memo.
- **Spacing:** no spacing literals in views; `Theme.Spacing` (`IrisUI/Theme/Spacing.swift`) holds the steps (`hair` 2 … `xl` 24) and the roles (`screenMargin` 20, `sectionTop`/`sectionBottom`, `rowVertical`, `rowColumnGap`, `rowLineGap`, `chipGap`, `barInset`, `barGap`, `cardInset*`), taken from the mockups' CSS. A missing value is added there with its mockup source. Control sizes (button and dash dimensions) are not spacing. No screen draws a title block (History, Stats, Settings, Diagnostics: the tab bar says where you are, content starts under the status-bar scrim). History hides the navigation bar and has a bottom search + filter + compose row (`HistorySearchBar`, three 44 pt targets), so everything sits on the 20 pt `screenMargin`. The memo detail (iOS and Mac pane) reads header → reply → player → transcript → Details (steps, cost per step, attempts, ids, retry; collapsed, open on a failed memo); per-screen deltas against the mockups: `docs/design/fidelity/`.
- **Strings:** English is the source, every user-facing string has a `de` entry (TDD §4 "Localization": forms, glossary, what is never localized). Catalogs per target: `Iris/Resources/` (+ `InfoPlist.xcstrings`), `IrisWidgets/Resources/`, `IrisMac/Resources/` (+ `InfoPlist.xcstrings`), `IrisUI/Resources/`. A SwiftUI literal is a `LocalizedStringKey`; a `String` is `String(localized:comment:)`; intents, widgets and controls take a `LocalizedStringResource` literal; in a package every one of them passes `bundle: #bundle`. `Text(verbatim:)` for data. A key's `%lld` / `%@` follows the interpolated type, a literal `%` is `%%`, a shared `Iris/*.swift` file needs its keys in each target's catalog that compiles it. `make check-strings` (in `check` and `check-apple`) fails on a missing or untranslated `de`, a `de` whose specifiers differ from the key's per argument index (every plural leaf too; German plurals need `one` and `other`, no empty branch, no index with two types), a positional key (`%1$lld`: the compiler extracts `%lld`), a stale key, a hard-coded literal, a `%lld` / `%@` mismatch it can see, a `Text(a ? "x" : "y")` or `Text("a" + "b")`, and in a package any literal that is not `Text(_, bundle: #bundle)` / `String(localized:, bundle: #bundle)` / `LocalizedStringResource(_, bundle: #bundle)` (only `#bundle` / `.module` count; modifiers like `.accessibilityLabel("x")` included); a step name shown to the user is `MemoStep.title`, never `rawValue`; `// l10n:ignore <why>` marks real data. Run the app in German with `-AppleLanguages "(de)" -AppleLocale de_DE`.
- **UI test waits:** a test never reads `exists`/`frame` of an element that may not be there in a loop; it uses `IrisUITestCase.waitForPresence` / `waitForAbsence` / `revealRow(containing:in:)`, which ask again when a query times out on a loaded runner (TDD §4 "UI tests on the hosted runner").
- **UI tests and the clock:** the fake sample memos are relative to a clock, and the UI tests pin it (`-IrisSampleNow <ISO-8601>`, `Tests/UITests/SampleClock.swift`: noon today),
  so History looks the same at 00:30 and at 14:00 (a memo from 90 minutes ago is on another day for the first hour and a half after midnight). The fake
  server's clock starts there and runs on, so a memo created in the app is newer than the samples. `HistoryDaySection.id` is (day, occurrence): two sections of one day must not share an id (SwiftUI dropped the rows).
- **Snapshots** only compare on the pinned simulator; a diff on a clean tree means a different runtime. They do not render the glass layer.
- **Mac capture** (Wave 18 M2, TDD §5): the global key is `KeyboardShortcuts` 3.1.0 on Carbon (no permission prompt, no `CGEventTap`), default **Control-Option-M** (Control-Option-Space is the system's input-source switch; research: `docs/research/2026-10-31-mac-hotkey.md`), recorded in Mac Settings. A press toggles a take through `RecordingPanelModel` → the `TakeEngine` port (`CaptureTakeEngine` over the iPhone's `CaptureStack`, `APIOutboxUploader` and the persistent outbox in the app container; `MacCaptureStack`) → the floating `NonActivatingPanel`. macOS has no `AVAudioSession`: `MacAudioSessionController` is a no-op and `DirectoryRouteManager` over Core Audio (`CoreAudioDeviceDirectory`) is the route manager; picking a microphone sets the system default input and the take's end puts the old one back. The original is persisted first (`RecoveringRouteManager`, `InputRecovery` in `UserDefaults`) and a kill mid-take is undone at the next launch (`RecoveringRouteManager.recover`). `-IrisFakeData` runs `FakeTakeEngine`, `FakeMicrophonePermission` and `FakeTakeHotkey` (no microphone, no prompt, no registration); the snapshot run adds `recording.png` (the real panel) and `recording-refused.png`. An unsigned build (CI, `check-apple`) never records; the stable-signing recipe and the hands-on rows (microphone prompt, real hotkey, a real take) are in `docs/spikes/device-checklist.md` "Mac hands-on rows". New files under `apple/IrisMac` need `make generate`.
- **Mac server binding** (Wave 19 M1, TDD §5): `MacCaptureStack` gives `CaptureStack` the saved connection's `serverKey` (work for another server is held back); `MacCompositionRoot.serverBox` is the `serverKey` of every `HistoryModel` it makes (stale answers dropped), and created memos reach History through `CreatedMemoLog.setServerHandler` + `insert(_:origin:)`.
- **Mac popover** (`docs/design/mockups/mac.html` variant `menu`): `MacMenuPanel` is the quick-access surface, `Theme.Spacing.menuWidth` wide (roles `menu*` in `Spacing.swift` with the CSS source), one page: `MacHomePage` has the title + the Hermes and Transcribe pair (`root.recording.toggle(mode:)`; the Hermes button shows the `.toggleTake` shortcut, the hotkey stays Hermes), the newest 5 memos as `MacMemoRow` (a click opens the main window on that memo, `root.show(id)`; context menu from `MacMemoActions`), the lines Open Iris (⌘O), Settings… (⌘,) and Quit Iris (⌘Q), and the connection line; with nothing saved a "Set Up Iris" button opens the onboarding window. The popover's list is always the unfiltered `root.history`.
- **Mac desktop app** (windows, not pages): three scenes declared in `IrisMacApp`, opened by the always-present `MenuBarLabel` when the root's counters change (`windowRequest`, `onboardingRequest`, `settingsRequest`; LSUIElement apps need `NSApp.activate()` first). `MacActivationPolicy` makes the app `.regular` (Dock, ⌘Tab) while a visible titled window that can be main exists and `.accessory` again after the last closes (pure rule `policy(for:)`; popover and recording panel are panels and never count).
  - **Main window "Iris"** (`MacMainWindow`, 1100x720): `NavigationSplitView` sidebar | list | detail. `MacSidebar` (Library: All memos, Favorites, Archive; Threads) selects `root.scope` (`MacLibraryScope`), which maps onto `HistoryFilters` (Threads = `setThread(true)`). The window has its own `root.windowHistory` (replaced on a connection change); it takes no stream of its own (the fake client has one consumer): `StreamTappingClient.mirror` hands every event of the popover's single stream to `followWindow`, handled only while the window is open (`windowDidAppear` / `windowDidDisappear`). `MacMemoList` (native `List(selection: $root.selectedMemoID)`, day sections, `.searchable`, Delete key, Space plays the recording; **the macOS `List` clips a row to 24 pt unless both `.environment(\.defaultMinListRowHeight, …)` and the row's `.frame(minHeight: …)` carry `Theme.Spacing.macRowMinHeight`**). `MacMemoDetailPane` + `MacMemoSections` (document layout: headline 18 pt, one metadata line, the kind chip, Reply via `MessageContentView(textRole: .footnote)` with the actions line under it, Summary, Transcript, Steps grid; a thread memo shows its conversation read only from `MacMemoDetailModel.thread`; Mermaid blocks show as code, the diagram image store is iOS only). Toolbar: play recording / reply (`MacAudioPlayer`, a bare `AVPlayer` over `MediaDownloader`, no `AVAudioSession`), copy, retry, favorite, archive, delete (undo toast via `macToast`). `root.selectedMemoID` / `show(_:)` is the one selection, cleared on a connection change.
  - **Settings scene** (⌘,, `MacSettingsView`): tabs Connection (URL, token, Test connection, Save, status), Recording (`KeyboardShortcuts.Recorder`), General (launch at login via `SMAppService.mainApp`, Quit). No microphone or spoken-reply setting on the Mac. `root.settingsTab` selects the tab (the snapshot run).
  - **Onboarding** (`MacOnboardingView`, 480x420): opens at launch when `root.needsOnboarding` (production, nothing saved) and from the popover's connect prompt; Continue is enabled once Test connection passed, saves, closes the window and opens the main window.
  - **Type and spacing:** the desktop uses `macFont(.caption|.body|.lead|.title)` (11 / 13 / 15 / 18 pt, `Theme.MacTextRole`), not the iPhone's basalt `themeFont` roles; spacing roles are `mac*` / `window*` in `Spacing.swift`. Window events are `mac.window` (`MacEvents.window`: window name, action, source; no memo).
  - `-IrisMacSnapshot <dir>` (fake composition) writes `menu`, `window-all`, `window-thread`, `window-filtered`, `settings-connection`, `settings-recording`, `settings-general`, `onboarding`, `recording`, `recording-longmic`, `recording-refused`; run it with `-AppleLanguages "(en)"` or `"(de)"` (window titles are localized). Windows with chrome are captured through `CGWindowListCreateImage` looked up with `dlsym` (the SDK marks it unavailable; it answers for the app's own windows without a Screen Recording grant); `cacheDisplay` leaves the sidebar, materials and toolbar blank.
- **Mac outbox panel** (Wave 19 M1, TDD §5): a strip under the panel header while the queue holds something (`MacOutboxStrip` / `MacOutboxModel` over `OutboxService`, the iPhone's
  `QueuedItemSource`: a count, a stalled item's reason, Retry now / Discard; `-IrisMacStalled` seeds it on fakes; put it after `-IrisMacSnapshot <dir>`: a launch flag between `-IrisMacPanelWindow` and `-IrisMacSnapshot` stops the panel window from being created).
- **Mac telemetry** (Wave 19 M1, TDD §5): the Mac writes the same device records as the iPhone with `service.name=iris-macos` (`MacTelemetry` builds the `DeviceLog`; `DeviceLog`,
  `DeviceLogCaptureEvents` and `ObservedSegmentUploader` are compiled in): add an event as `MacEvents` / `DeviceLog.event`, never a bare `Logger` call, and never a transcript, reply, park
  reason, banner text, token, URL or device id in one. Mac-only names: `mac.panel`, `mac.window`, `mac.hotkey`, `audio.input_switch`, `audio.input_recovery`, `notify.mac`, `outbox.user_action`, `app.lifecycle`.
- **Mac notifications** (`MemoNotifier`, TDD §5) announce a **transition** into finished (`notified`) or failed (the title is the memo's kind), from the open event stream
  (`memo.updated` / `memo.done` states) and from the catch-up after each `ready`: an unfiltered fetch of the newest 50 memos (the first of a connection is the silent
  baseline; later ones announce memos that reached a kind meanwhile, at most 5, newest first). A state that is not a kind clears the record, so a retried memo announces
  again; the memo is fetched fresh before it posts. Banners never carry the transcript, reply or park reason. A connection switch withdraws the old server's banners
  (and one posted during the switch); **known limit:** a memo that finished while the app was not running is not announced (no APNs yet).
- **`scripts/mbm tap`** needs `--element-ref` from the latest `snapshot-ui` and `--post-delay 2`; `snapshot-ui` straight after a launch times out
  (`make ui-snapshot` waits first). Live Activity, widgets and the notification card compile but have never been rendered; the Mac panel renders on the mini
  (`IrisMac -IrisFakeData -IrisMacPanelWindow -IrisMacSnapshot <dir>` writes PNGs of its own windows; `screencapture` has no Screen Recording grant there); the
  AVAudioEngine recorder and the interruption paths (incl. the lock-time interruption fix of Wave 17 I7: reactivate the session,
  rebuild the engine, auto-finish a failed take) and the engine restart on a route change (fresh engine, validated tap format, `IrisObjCGuard` shim) are covered by fakes only until the device check passes (`docs/spikes/device-checklist.md`).
- **TDD is the design, code is the truth for shipped behaviour:** §3 was amended in Wave 8 to match the server; planned-but-unbuilt items are marked there.
