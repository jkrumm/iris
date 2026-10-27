# Iris — foundation chain (server R0 + monorepo setup)

**Goal:** `iris-server` runs on the mini behind `iris.mini.<domain>` and passes a real
end-to-end memo, with the trace visible in HyperDX. The monorepo also carries the
contracts, the Apple scaffold (XcodeGen + local packages + CI), the agent tooling
(skills, MCP, verification harness), and an HTML mockup round of the UI, ready for the
long-running fleet that builds R1–R5.
**Gate:** `make check` green (it grows: server → contracts → apple), then `/review` with its
findings resolved. From Wave 4 on, `make verify` too. Apple waves without a local Xcode
gate on the `apple.yml` CI run instead.

Design source: **`docs/TDD.md`**, which wins over anything here except the step lists.
`docs/PRD.md` is the product. `docs/PLAN.md` is superseded. **Public repo:** no real
hostnames, IPs, tailnet names, tokens or emails in any tracked file. Use placeholders
(`<domain>`, `iris.mini.<domain>`); `op://` references in `.env*.tpl` are fine.

Conventions to copy, not invent (paths are relative to `~/SourceRoot`):
- **Lint and format:** `agent-gateway/.oxlintrc.json`, `.oxfmtrc.json`. Tests are colocated `*.test.ts`.
- **Ports and adapters:** in the email-gateway style (`email-gateway/src/providers/port.ts`,
  its AGENTS.md "testing" rules). Dependencies are injected, tests use in-memory SQLite and
  fake ports, there is no `mock.module` or `spyOn`, and HTTP is tested via
  `app.handle(new Request())`.
- **Telemetry:** copy `research-gateway/src/lib/otel.ts`, `otel-format.ts` and `log.ts`
  (hand-rolled OTLP JSON, no SDK). The trace id is the memo UUID with the dashes stripped.
- **Mini service lifecycle:** `research-gateway/deploy/MINI.md`, `scripts/launch.sh`,
  `launchd/*.plist.template`, `Makefile` (check/deploy/verify/logs, `.DEFAULT_GOAL := help`).
- **Repo contract:** `dotfiles/docs/agents-md.md` (AGENTS.md only, the required sections).
  CI runs on hosted runners (public repo).

Downstream facts: `docs/TDD.md` §3 "Downstream facts". Secrets: use `secrets-run`, never
`op`, on the mini. New refs go into `dotfiles-private/headless.refs`. Seeding is
`~/SourceRoot/dotfiles/scripts/ask-human.sh ask … --cmd 'make secrets-seed'`.

## Wave 1 — Repo foundation            <!-- status: done -->
- [x] `gh repo create jkrumm/iris --private --source . --push`, then
      `make -C ~/SourceRoot/vps gh-runner-sync`
- [x] Scaffold `server/` (Bun + Elysia + `bun:sqlite`, TypeScript strict) and the root
      `Makefile` (`check` = `check-server`, which also leaves room for a later
      `check-apple`). Add the oxlint/oxfmt configs, `.gitignore`, and
      `.github/workflows/check.yml` on the self-hosted VPS runner.
- [x] `server/src/telemetry/` copied from research-gateway with `service.name=iris-server`.
      Add `app.ts` as the composition root, `index.ts` as the entry point, and `GET /health`.
- [x] Device-token auth (a `IRIS_DEVICE_TOKENS` map of token to device name, the
      audio-gateway caller-token pattern) as an Elysia guard on `/v1/*`, with tests.
- [x] Write `AGENTS.md` with the required sections: Validate, Deploy (placeholder until
      Wave 4), Verify & Monitor, Gotchas.
**Left behind:** Repo `jkrumm/iris` (private, master, runner `vps-iris` registered, CI is `make check-server`).
`server/` has `src/{app,index,env}.ts`, `src/http/auth.ts` (`parseDeviceTokens`, `deviceAuth(tokens)` derives
`device`; mounted under `/v1` in `createApp({deviceTokens, degraded})`), `src/telemetry/` (copy of research-gateway;
`traceIdFromMemoId`). `process.env` is parsed only in `env.ts`. Root `make check` is green (46 tests), and
`/review` was clean. Not done, deliberately: rejecting an `http://` OTLP endpoint when an auth header is set (the
mini endpoint is https; revisit in Wave 4). The Makefile has no deploy/verify/logs yet (Wave 4), and the lint config
lives in `server/`.

## Wave 2 — Memo domain + HTTP surface            <!-- status: active -->
- [ ] `memo/`: the Memo state machine (`receiving → received → transcribed → routed |
      needs_route → acted → summarized → notified`, with `failed(step)` as a side state),
      the `MemoStore` port, and a SQLite adapter with migrations. The memo id is
      client-supplied (UUID v4).
- [ ] `POST /v1/memos` (idempotent create: mode, device, started_at),
      `PUT /v1/memos/:id/segments/:n` (raw bytes, idempotent by index, stored under
      `$IRIS_DATA/audio/<id>/`), and `POST /v1/memos/:id/complete {segment_count}`, which
      rejects with the list of missing indices if segments are absent.
- [ ] `GET /v1/memos` (paged), `GET /v1/memos/:id` (with the step timeline),
      `GET /v1/memos/:id/result?wait=<s>` (long-poll that resolves on a terminal state),
      and `GET /v1/events` (SSE of memo state changes).
- [ ] An idempotent step runner: on startup and on each `complete`, drive every
      non-terminal memo from its last finished step. A failed step records its error, and
      `POST /v1/memos/:id/retry {from}` re-drives it.
**Left behind:**

## Wave 3 — Pipeline            <!-- status: pending -->
- [ ] `ports/` (Transcriber, Destination, Summarizer, Notifier, Clock) plus fakes for tests.
- [ ] Adapters:
  - `audio-gateway.ts`: concatenates with ffmpeg, then STT.
  - `hermes.ts`: the sessions API, collecting the final assistant text from the SSE.
  - `agw.ts`: triage with the schema `{headline ≤60, detail ≤240, spoken ≤2 sentences}`,
    job submit plus poll with a timeout.
  - `notifier-log.ts`: log-only.
- [ ] Wire the steps into the runner. In this chain the route is always `hermes` (the
      `decide` routing is Phase 2). Each step is a child span of `withRootSpan("memo")`.
      Store the per-step `usage`/`cost` from the responses on the memo.
- [ ] `scripts/send-memo.ts <audio-file>`: splits a file into 10 s m4a segments with
      ffmpeg and drives the HTTP API exactly like the phone will. It is the end-to-end
      harness for this chain and for later debugging.
**Left behind:**

## Wave 4 — Run it on the mini            <!-- status: pending -->
The owner pre-authorized this deploy on 2026-10-27: it is his own repo, mini-only, and the
standing contract says deploys are routine. So Wave 3 spawns this wave with
`RD_ORCHESTRATED=1 rd wave iris '…'`.
- [ ] `scripts/launch.sh` plus `.env.local.tpl` / `.env.mini.tpl` / `.env.mini.otel.tpl`
      (research-gateway pattern). Add the new refs to `dotfiles-private/headless.refs`
      and seed them. The device tokens are generated, stored in 1Password `tkrumm`, and
      never written into the repo. `APNS_*` stays unset: the log `Notifier` runs until
      enrollment completes.
- [ ] Deploy clone `~/.iris/app`, data in `~/.iris/data`. Add `launchd/` templates for
      `com.jkrumm.iris` (KeepAlive) and `com.jkrumm.iris-deploy` (a 120 s poller, CI-green
      and idle gated), plus the `make launchd-install` and `mini-setup` targets.
- [ ] Caddy door `iris.test` → `localhost:7730` (confirm the port is free first) in
      `dotfiles/config/Caddyfile`, then `make caddy-tailnet`. Add rows for both labels to
      `dotfiles/docs/architecture.md`. Commit in dotfiles separately (`architecture-check.sh`
      must stay green).
- [ ] End to end: run `scripts/send-memo.ts` against `https://iris.mini.<domain>` with a
      real German voice recording of more than 60 s. The memo must reach `notified`, a
      Hermes session must hold the message, and the trace must be visible in HyperDX
      (`/otel`). Wrap it as `make smoke`. Fill in AGENTS.md Deploy and Verify & Monitor.
**Left behind:**

## Wave 5 — Contracts + server completion for R1            <!-- status: pending -->
- [ ] `contracts/`: a JSON Schema and a fixture for every `/v1` request, response and SSE
      event that exists (TDD §3 API, D9). Elysia TypeBox schemas export to JSON Schema.
      `make check-contracts` asserts that the export equals `contracts/schema` and that the
      fixtures validate. It joins `make check` and CI.
- [ ] `IRIS_FAKES=1` boot mode, where every port uses its fake. `make e2e` runs
      `send-memo.ts` against a fake-booted server, in CI.
- [ ] The missing R1 endpoints from TDD §3: `devices/register`, `memos/:id/activity-token`,
      `memos/:id/audio`, `memos/:id/speech` (TTS cached), `GET /v1/herd` (herdr adapter,
      snapshot only).
- [ ] APNs `Notifier` (TDD D6): `@parse/node-apn` on Bun `node:http2` with in-flight
      streams capped at 10, the ES256 provider token refreshed every 50 min, the
      alert payload, and the Live Activity update/end payloads (TDD §3 notify). Unit tests
      use a fake transport. Selected only when `APNS_*` is set; otherwise the log Notifier.
      Read `docs/research/2026-10-27-apns-from-bun.md` first.
- [ ] Public-repo guard: a pre-commit hook (lefthook) plus a CI step that rejects IPv4s,
      `*.ts.net`, the real domain pattern and token shapes in tracked files.
**Left behind:**

## Wave 6 — Apple monorepo scaffold            <!-- status: pending -->
Check `xcodebuild -version` first. If Xcode 27.1 is installed locally, gate locally too.
Otherwise the `apple.yml` CI run is the gate (`gh run watch`).
- [ ] `apple/project.yml` (XcodeGen 2.46+, `brew install xcodegen` if missing): targets
      `Iris`, `IrisWidgets`, `IrisNotifications`, `IrisMac`. Bundle ids, App Group
      `group.com.jkrumm.iris`, entitlements, Info.plist keys (`UIBackgroundModes: audio`,
      `NSSupportsLiveActivities`, `NSMicrophoneUsageDescription`, `LSUIElement` for Mac),
      iOS/macOS 26.0 minimum, Swift 6 mode, and MainActor default isolation for the app
      targets. **Verify the build-setting spelling against the installed toolchain or
      the CI image, and record it in TDD §6.** `.xcodeproj` is gitignored.
- [ ] Local packages `apple/Packages/{IrisCore,IrisCapture,IrisUI,IrisTelemetry}` with
      their public interfaces stubbed per TDD §4–§8:
  - `IrisCore`: models, an API client, an SSE parser, and decoding tests over every
    `contracts/fixtures` file;
  - `IrisCapture`: protocols for `AudioSessionController`, `RouteManager`,
    `SegmentRecorder` and `Outbox`, plus `FakeCapture`, with segment-rotation and outbox
    state-machine tests on fakes;
  - `IrisUI`: `Theme` generated from basalt-ui tokens by a script, plus a swift-snapshot-
    testing setup with one reference;
  - `IrisTelemetry`: a buffer plus a relay exporter.
- [ ] Thin app targets that compile and launch to a placeholder history (fed from fake
      data). The widget extension has a placeholder Control and Live Activity; the
      notification extension has a placeholder card. The Mac target is a MenuBarExtra
      placeholder.
- [ ] `.swift-format` + `swift format lint --strict`, and Make targets `generate`,
      `check-apple` (lint, `swift test` per package, `xcodebuild build` of all schemes for
      the simulator), `snapshots` (`RECORD=1`), and `uitest`. Add
      `.github/workflows/apple.yml` on `runs-on: xcode-27` (TDD D14; fall back to `macos-26`
      only if the image queues for more than 30 min). `check-apple` joins `make check` when
      `xcodebuild` exists locally.
**Left behind:**

## Wave 7 — Agent tooling + verification harness            <!-- status: pending -->
- [ ] `.mcp.json` with MobileBuildMCP pinned to an exact version (TDD §10). Document the
      per-machine `claude mcp add --transport stdio xcode -- xcrun mcpbridge`, and the one-time
      Xcode setting it needs, in AGENTS.md.
- [ ] Vendor `swiftui-pro`, `swift-concurrency-pro` and `swift-testing-pro` from `twostraws/*`
      into `.claude/skills/`. Check each LICENSE is MIT and copy it alongside. Pin commits in
      `.claude/skills/VENDORED.md`.
- [ ] Own skills (TDD §10): `iris-server`, `ios-verify`, `device`, `memo-debug`,
      `apple-capture-notes`. Each has a short SKILL.md whose commands were actually run (or,
      without local Xcode, marked `unverified until Xcode` in one line).
- [ ] `fixtures/audio/de-90s.m4a`: a German sample generated through audio-gateway TTS
      (`x-audio-source: iris`), used by `make e2e` and `make smoke`. Write
      `docs/spikes/device-checklist.md` (TDD §9, hardware-only rows) and the S1–S3 spike
      briefs in `docs/spikes/`.
- [ ] Rewrite AGENTS.md for the monorepo: layout, the full Validate matrix, the public-repo
      rule, Xcode/MCP setup, the skills index, Gotchas. Point it at TDD/PRD.
**Left behind:**

## Wave 8 — UI mockup round            <!-- status: pending -->
- [ ] `docs/design/mockups/`: static HTML using the basalt-ui tokens (the same values as
      `IrisUI/Theme`), styled to read as iOS 26 Liquid Glass. Surfaces: History, Memo detail
      (step timeline, cost, retry), Record (timer, waveform, mic picker, mode/tab picker),
      Live Activity (recording / processing / done / needs-route, Lock Screen + Dynamic
      Island), the notification card, the Mac panel. Use realistic German and English
      sample content.
- [ ] Render each surface to PNG (chrome-devtools screenshot at device sizes), upload via
      `/img` as private presigned links, and list them in `docs/design/README.md`.
- [ ] Stop here: the owner reviews the mockups. Write "stopped: owner reviews mockups;
      then the fleet starts R1 from the Fleet backlog" into **Left behind** and do not
      spawn.
**Left behind:**

## Fleet backlog (for the long-running fleet: mother → lead → workers)

Not waves of this chain. The fleet's mother turns these into active waves, one at a time,
refining scope from TDD/PRD. Releases are named in PRD §Release plan.

1. **Spikes S1–S3** on the iPhone: these need the owner's hands, Xcode on the mini and
   phone pairing. S1: Lock Screen control → `AudioRecordingIntent` → Live Activity → a
   30-min take while switching apps and locking. S2: a mic switch mid-take, built-in mic
   while connected to the car. S3: APNs Live Activity update + [Play] from a suspended
   app. Findings go to `docs/spikes/`, and TDD gets amended.
2. **R1 capture:** `IrisCapture` for real (session, routes, segment recorder, outbox),
   `StartMemoIntent` + Control + Live Activity, the Record screen, `-IrisFakeCapture` UI
   tests.
3. **R1 results:** APNs registration, notification categories + content extension, the
   result long-poll backstop, Live Activity remote updates. TestFlight pipeline
   (`make testflight`) once enrolled.
4. **R2 routing (server):** prefix parser, `decide`, journal + herdr destinations,
   `needs_route`, corrections, templated summaries, agw `caller` field (a small change in
   agent-gateway).
5. **R2 routing (iOS):** mode/tab picker, needs-route actions, [Play] via `PlayReplyIntent`,
   per-route mic rules, spoken-replies setting.
6. **R3 history:** history + search, memo detail (timeline, cost, retry, scrubber), SSE live
   updates.
7. **R3 threads:** the Hermes thread view (Textual), reply by voice into a thread.
8. **R4 Mac:** the menu-bar app, hotkey, panel, capture on the Mac, SSE notifications.
9. **R5 polish:** on-device live preview (`SpeechTranscriber`, German checked at runtime),
   widgets, spoken-replies mode, alerts + health probe (TDD §8 Later).

