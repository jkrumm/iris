# Iris — foundation chain (server R0 + monorepo setup)

**Goal:** `iris-server` runs on the mini behind `iris.mini.<domain>` and passes a real
end-to-end memo, with the trace visible in HyperDX. The monorepo also carries the
contracts, the Apple scaffold (XcodeGen + local packages + CI), the agent tooling
(Swift rules, vendored + own skills, CLI verification harness), and an HTML mockup round of the UI, ready for the
long-running fleet that builds R1–R5.
**Gate:** `make check` green (it grows: server → contracts → apple), then `/review` with its
findings resolved. From Wave 4 on, `make verify` too. Apple waves without a local Xcode
gate on the `apple.yml` CI run instead.

Design source: **`docs/TDD.md`**, which wins over anything here except the step lists.
`docs/PRD.md` is the product. **Public repo:** no real
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

## Wave 2 — Memo domain + HTTP surface            <!-- status: done -->
- [x] `memo/`: the Memo state machine (`receiving → received → transcribed → routed |
      needs_route → acted → summarized → notified`, with `failed(step)` as a side state),
      the `MemoStore` port, and a SQLite adapter with migrations. The memo id is
      client-supplied (UUID v4).
- [x] `POST /v1/memos` (idempotent create: mode, device, started_at),
      `PUT /v1/memos/:id/segments/:n` (raw bytes, idempotent by index, stored under
      `$IRIS_DATA/audio/<id>/`), and `POST /v1/memos/:id/complete {segment_count}`, which
      rejects with the list of missing indices if segments are absent.
- [x] `GET /v1/memos` (paged), `GET /v1/memos/:id` (with the step timeline),
      `GET /v1/memos/:id/result?wait=<s>` (long-poll that resolves on a terminal state),
      and `GET /v1/events` (SSE of memo state changes).
- [x] An idempotent step runner: on startup and on each `complete`, drive every
      non-terminal memo from its last finished step. A failed step records its error, and
      `POST /v1/memos/:id/retry {from}` re-drives it.
**Left behind:** Memo domain and HTTP surface are done; `make check` (141 tests) and `fallow audit` are green,
`/review` blocker (same-index upload race) fixed. Layout: `memo/{memo,store,events,runner,service,errors}.ts`
(pure state machine, `MemoStore` port, single-flight `Runner`, deep `MemoService`), `adapters/{sqlite,audio-fs}.ts`
(migrations in `sqlite-migrations.ts`; `ports/{clock,audio}.ts`, so Wave 3 adds the other ports beside `Clock`),
`http/{memos,events,errors,serialize}.ts`. `index.ts` is the production composition root and passes an EMPTY
handler map: Wave 3 registers `Partial<Record<transcribe|route|act|summarize|notify, StepHandler>>` in `index.ts`
(`StepHandler = ({memo}) => {outcome?, usage?, costUsd?}`; the runner already opens `withRootSpan("memo")` with a child
span per step and stores `usage`/`costUsd` on `memo_steps`). Until then a completed memo parks at `received`.
Wire format follows TDD §3, not the step lists above: camelCase JSON (`startedAt`, `segmentCount`), 422 for missing
segments, segment PUT idempotent by sha256 (same sha 200, different 409), SSE `memo.updated` + `memo.done`.
Trust model: all device tokens equal, ownership checked only on create (AGENTS.md Gotchas).
Carry into Wave 3: (1) make handlers idempotent; `runStep` does `markStepDone` and `transition` as two writes, so put
them in one `db.transaction` and keep handler errors apart from bookkeeping errors; (2) `driveAll()` starts every
non-terminal memo at once, so bound it (2 to 4) before real backends are behind it; (3) shutdown does not drain the
runner before `db.close()`, so add `runner.idle()` once handlers do real work; (4) `getActiveSpan` is unused
(fallow warning) until a step enriches its span. Open owner question: memos stuck in `receiving` (uploads cut off)
keep rows and files forever; Phase-1 retention (purge after N days vs. keep for resume) is undecided. A segment
upload racing `complete` can leave one orphan file (harmless, no row). Untouched on purpose: the `http://` OTLP
endpoint with an auth header (Wave 4).

## Wave 3 — Pipeline            <!-- status: done -->
- [x] `ports/` (Transcriber, Destination, Summarizer, Notifier; `Clock` and `AudioStore` already exist) plus fakes for tests.
- [x] Adapters:
  - `audio-gateway.ts`: concatenates with ffmpeg, then STT.
  - `hermes.ts`: the sessions API, collecting the final assistant text from the SSE.
  - `agw.ts`: triage with the schema `{headline ≤60, detail ≤240, spoken ≤2 sentences}`,
    job submit plus poll with a timeout.
  - `notifier-log.ts`: log-only.
- [x] Wire the steps into the runner. In this chain the route is always `hermes` (the
      `decide` routing is Phase 2). Each step is a child span of `withRootSpan("memo")`.
      Store the per-step `usage`/`cost` from the responses on the memo.
- [x] `scripts/send-memo.ts <audio-file>`: splits a file into 10 s m4a segments with
      ffmpeg and drives the HTTP API exactly like the phone will. It is the end-to-end
      harness for this chain and for later debugging.
**Left behind:** Pipeline is wired end to end; `make check` green (220 tests), `/review` run via the `agw review` CLI (the MCP
child timed out; the senior-dev and backend angles were denied a shell in both runs, so only concurrency/resilience/
architect/typescript/adversary angles reported). Layout: `ports/{transcriber,destination,summarizer,notifier,fakes}.ts`,
`adapters/{audio-gateway,hermes,agw,notifier-log,sse}.ts`, `pipeline/steps.ts` (`createStepHandlers`, a port left out means no
handler and the memo parks; `index.ts` marks it `degraded`). Memo data lives in columns on `memos` (transcript, route,
audioSeconds, destinationRef, replyText, summary) and is returned by `GET /v1/memos/:id/result`. `store.completeStep` is one
transaction (CAS, step done, patch); `Runner.stop()/idle()/inflightIds()`; `driveAll` is capped at 3. Shutdown: stop, drain up
to 30 s, close DB, flush OTel (2 s), so **Wave 4's LaunchAgent needs `ExitTimeOut` >= 45 s**. New env: `AUDIO_GATEWAY_URL`,
`AGW_URL`, `HERMES_URL`, `HERMES_TOKEN` (all optional). Timeouts follow `agent-limits.md`: Hermes idle watchdog 5 min, 30 min
hang guards on STT and the agw poll. `scripts/send-memo.ts` (`IRIS_URL`, `IRIS_TOKEN`, `--mode`, `--wait`) works against an
in-process fake in tests only; it has never run against real downstreams.
Carry into Wave 4: (1) Hermes request shape is unverified live: the adapter sends `{message}` only (no `system_message`) with
the session id = memo id and `source: "iris"`; `make smoke` is the first real test, adjust if Hermes rejects it. (2) `act` is
at-least-once: a crash after the Hermes turn replays it (documented in AGENTS.md). (3) A downstream that is down at boot turns the
memo `failed` (no automatic retry of transient errors; recover with `POST /retry`); consider boot ordering in launchd. (4) An
agw triage job orphaned by a crash is resubmitted (small cost). (5) Not done on purpose: dedupe of `SummarySchema` between
`sqlite.ts` and `agw.ts`, removing the unused `markStepDone` from the port, a step-to-patch-field map. (6) `server`'s `bun test`
does not run `scripts/*.test.ts`; lint/format/tsc do cover `scripts/`. `fallow audit` reports 3 complexity advisories
(not in the gate). (7) The retention question for stuck `receiving` memos is still open.


## Wave 4 — Run it on the mini            <!-- status: done -->
The owner pre-authorized this deploy on 2026-10-27: it is his own repo, mini-only, and the
standing contract says deploys are routine. So Wave 3 spawns this wave with
`RD_ORCHESTRATED=1 rd wave iris '…'`.
- [x] `scripts/launch.sh` plus `.env.local.tpl` / `.env.mini.tpl` / `.env.mini.otel.tpl`
      (research-gateway pattern). Add the new refs to `dotfiles-private/headless.refs`
      and seed them. The device tokens are generated, stored in 1Password `tkrumm`, and
      never written into the repo. `APNS_*` stays unset: the log `Notifier` runs until
      enrollment completes.
- [x] Deploy clone `~/.iris/app`, data in `~/.iris/data`. Add `launchd/` templates for
      `com.jkrumm.iris` (KeepAlive) and `com.jkrumm.iris-deploy` (a 120 s poller, CI-green
      and idle gated), plus the `make launchd-install` and `mini-setup` targets.
- [x] Caddy door `iris.test` → `localhost:7730` (confirm the port is free first) in
      `dotfiles/config/Caddyfile`, then `make caddy-tailnet`. Add rows for both labels to
      `dotfiles/docs/architecture.md`. Commit in dotfiles separately (`architecture-check.sh`
      must stay green).
- [x] End to end: run `scripts/send-memo.ts` against `https://iris.mini.<domain>` with a
      real German voice recording of more than 60 s. The memo must reach `notified`, a
      Hermes session must hold the message, and the trace must be visible in HyperDX
      (`/otel`). Wrap it as `make smoke`. Fill in AGENTS.md Deploy and Verify & Monitor.
**Left behind:** iris-server is live on the mini and passed a real end-to-end memo: `IRIS_URL=https://iris.mini.<domain> make smoke`
went `notified` in 10.6 s (96 s German TTS recording, 5 steps timed, $0.0002), the Hermes session (id = memo id) holds the
user and assistant turn, and HyperDX shows one `memo` trace with 13 OK spans plus 3 correlated logs (`/otel`, prod). Hermes accepted
the Wave-3 request shape unchanged. `make check` green (221 tests), `/review` run via the `agw review` CLI (MCP job stalled again
and was cancelled; security + resilience angles). Layout: `scripts/{launch,mini-deploy,smoke}.sh`, `launchd/*.plist.template`,
`.env.{local,mini,mini.otel}.tpl`; root `Makefile` gained `mini-setup, launchd-{install,uninstall,status,restart,logs}, deploy,
verify, logs, smoke`. Port 7730 is free on loopback (the `rb` tailscale-serve row of the same number is a tailnet-interface
binding, no conflict). Secrets: new 1Password item `op://mini/iris/{device-tokens,audio-gateway-url,otel-endpoint}` (tokens
generated on the MacBook for devices `iphone`, `macbook`, `smoke`; the iPhone token is for the app later), refs added to
`dotfiles-private/headless.refs` and seeded; Hermes host/key and the HyperDX key reuse existing refs. `HERMES_URL` is composed
in `launch.sh`. `/health` gained `inflight` (the poller's idle gate); `ExitTimeOut` 60 s. Deploy poller: CI `check` green on the
SHA + idle, restarts only for runtime paths, proven live (restart, pid change, marker). Review fixes: a failed restart rolls back to the
previous SHA and records `~/.iris/failed-sha` (skipped until a newer push), and a changed `launchd/` template writes
`~/.iris/launchd-pending` so `make verify` fails until `make launchd-install` runs. **The rollback path and the pending marker
are unit-untested and unverified live** (a broken SHA cannot pass the CI gate). Dotfiles: `Caddyfile` door `iris.test` (+ the
generated `iris.mini.<domain>`) and `architecture.md` rows, commit `d7ef7ba`, pushed. `scripts/architecture-check.sh` exits 1
on four `com.iu.teamchat-*` rows mapped but absent on the mini; that predates this wave and is untouched (no iris label is unmapped).
Wave 8 inherits `fixtures/audio/de-90s.m4a` (actually 96 s, generated with the audio-gateway Gemini TTS, voice Charon, via
`x-audio-source: iris`, so it is TTS and not a human voice); its remaining Wave-8 work is the doc and spike items. Not done on
purpose: `jobrun` reports a CI-red tick as success (exit 0, same as research-gateway); `make e2e` is Wave 5.

## Wave 5 — Contracts + server completion for R1            <!-- status: done -->
- [x] `contracts/`: a JSON Schema and a fixture for every `/v1` request, response and SSE
      event that exists (TDD §3 API, D9). Elysia TypeBox schemas export to JSON Schema.
      `make check-contracts` asserts that the export equals `contracts/schema` and that the
      fixtures validate. It joins `make check` and CI.
- [x] `IRIS_FAKES=1` boot mode, where every port uses its fake. `make e2e` runs
      `send-memo.ts` against a fake-booted server, in CI.
- [x] The missing R1 endpoints from TDD §3: `devices/register`, `memos/:id/activity-token`,
      `memos/:id/audio`, `memos/:id/speech` (TTS cached), `GET /v1/herd` (herdr adapter,
      snapshot only).
- [x] APNs `Notifier` (TDD D6): `@parse/node-apn` on Bun `node:http2` with in-flight
      streams capped at 10, the ES256 provider token refreshed every 50 min, the
      alert payload, and the Live Activity update/end payloads (TDD §3 notify). Unit tests
      use a fake transport. Selected only when `APNS_*` is set; otherwise the log Notifier.
      Read `docs/research/2026-10-27-apns-from-bun.md` first.
- [x] Public-repo guard: a pre-commit hook (lefthook) plus a CI step that rejects IPv4s,
      `*.ts.net`, the real domain pattern and token shapes in tracked files.
**Left behind:** All five steps shipped; `make check` (server, contracts, guard; 382 tests) and `make e2e` are green locally, CI runs
`make check` then `make e2e` (job still named `check`, the deploy poller gates on it). `/review` (deep, agw MCP) found 1 blocking +
5 improvements; all fixed except the composition refactor below. **Contracts:** `contracts/{schema,fixtures,manifest.json}` (25 schemas,
54 fixtures) are generated from `server/src/http/schemas.ts` (`make contracts`, `make check-contracts`); the check enumerates the real
app's routes, so a new `/v1` route fails until it has a manifest entry; fixtures are validated with ajv and key-compared with live
responses. Fixture variants are `<name>.<variant>.json`; Wave 7 decodes every file. **Endpoints:** `devices/register`,
`memos/:id/activity-token` (204), `memos/:id/audio` (cached concat, Range 206), `memos/:id/speech` (cached mp3, sidecar `.txt`), `GET /v1/herd`
(herdr `session.snapshot`, `lastActivity` always null: the snapshot has no timestamps); new `unavailable` 503 code, `DeviceStore` port
(devices keyed by auth device name, activity tokens per memo). **APNs:** `@parse/node-apn` 8.1.0 (library refreshes the JWT every 55 min,
inside Apple's window; TDD says 50), our transport caps in-flight streams at 10 and sends the first request alone; verified against a local
`node:http2` TLS server on Bun (ES256 raw r||s verifies via WebCrypto, headers, 10-stream cap); NOT verified: real Apple hosts/cert chain, GOAWAY
parsing, the 4 KB limit at Apple. Selected only when all four `APNS_*` are set, not listed in `degraded` (log notifier is intended until
enrollment). A BadDeviceToken only clears a token when `apnsEnv` was registered explicitly; the alert carries `apns-collapse-id` = memo id so a
notify retry replaces the banner. **Swift-side contract for Wave 7:** Live Activity `ContentState` is `{phase, routeChip?, headline?, hasReply}` plain
camelCase; `inputName` is never sent, so the client must declare it optional; alert category is always `MEMO_DONE`, custom key `memo` = memo id.
**Fakes:** `IRIS_FAKES=1` (`server/src/compose-fakes.ts`, `/health` lists `fakes`, `launch.sh` refuses to start with it set). **Guard:**
`scripts/public-guard.ts` (`make guard`, lefthook pre-commit, in `make check`); the real-domain literals live in untracked
`~/.config/iris/guard-extra.txt` (seeded on the mini; CI relies on the generic infra-host rule only, so other machines need the file or
`IRIS_GUARD_EXTRA`). `scripts/launch.sh` now exports `HERDR_SOCKET`; this is not deployed yet, the deploy poller picks it up after push.
Carry forward: (1) TDD §3 is stale vs the shipped code (data model: `devices` keyed by device name, no `route_decisions`/`threads`/`steps` tables,
`memo_steps` has no `attempt`; API table lists routes that do not exist: `/route`, `/threads*`, `/telemetry`, `?q`; `POST /memos` takes no `targetTab`/
`threadId`/`language`; the token refresh value) and §11 names `server.yml` where the workflow is `check.yml`: Wave 8's AGENTS/doc pass should amend
it. (2) Not done on purpose: dedupe of production and fakes composition in `index.ts`/`compose-fakes.ts` (a `downstreams(env, {fakes})` record would make a
missing port a compile error; the speech cache is only faked in one branch); `MEMO_NEEDS_ROUTE` alert category (unreachable until Phase 2 routing);
`+faststart` on the concat output (AVPlayer's first seek is slower with `moov` at the end). (3) Alert + Live Activity `end` still go out in parallel, so a
partial transient failure re-sends the Live Activity `end` on retry (harmless). (4) Pre-existing lint warnings in untouched files remain
(`runner.ts`, `test-support.ts`). (5) Apple/CI-only gaps: first real push needs enrollment and a device token; the `apple.yml` workflow is Wave 7.

## Wave 6 — Swift / Apple dev layer (in iris)            <!-- status: done -->
Iris is the owner's only Swift project (shutterflow and WeatherOrb will use Tauri / React
Native with basalt-ui), so the generic Swift layer lives in this repo's `.claude/`, not in
dotfiles. Only machine toolchain setup goes into dotfiles. Read
`docs/research/2026-10-27-agent-dev-tooling.md` and `docs/research/2026-10-27-swiftui-design.md`
first.
- [x] `.claude/rules/swift.md`, lazy, with `paths: ["**/*.swift", "**/Package.swift",
      "**/project.yml", "**/*.xcconfig"]`. It covers:
  - Swift 6 language mode with complete concurrency checking, MainActor default for app
    targets, and actors / `Sendable` instead of locks;
  - `@Observable` (not `ObservableObject`);
  - Swift Testing (not XCTest) except for UI tests;
  - ports and adapters as protocols with in-memory fakes (no mocking frameworks);
  - `os.Logger`, no `print`;
  - no force unwraps or `try!` outside tests;
  - `swift format`;
  - research-first for any iOS 26/27 / macOS 26 API (the training cutoff predates them);
  - the vendored skills to load.
  Keep it ≤ 80 lines and modelled on `~/SourceRoot/dotfiles/rules/typescript.md`.
- [x] Vendor `twostraws/SwiftUI-Agent-Skill` (`swiftui-pro`) and the sibling
      `swift-concurrency-pro`, `swift-testing-pro` and `swiftdata-pro` skills (see
      `twostraws/Swift-Agent-Skills`) into `.claude/skills/<name>/`. Verify each LICENSE is MIT
      and copy it in, pinning commit SHAs in `.claude/skills/VENDORED.md` with an update
      procedure.
- [x] `.claude/skills/apple-dev/SKILL.md`: the mini's Apple toolchain and recipes, each
      command actually run once on the mini:
  - Xcode via `xcodes` at `~/.local/bin` (brew build broken), `xcode-select`, simulator
    runtimes (`xcodes runtimes`), XcodeGen;
  - `xcodebuild` build/test/archive with `-allowProvisioningUpdates`;
  - `simctl` (boot + `bootstatus -b`, install, launch, `io screenshot`, `openurl`, `push`);
  - `devicectl` install/launch;
  - the `mobilebuildmcp` CLI for UI automation (no MCP servers, owner decision);
  - `pymobiledevice3` device screenshots;
  - headless signing (`security set-key-partition-list`), TCC + stable signing identity
    for Mac apps, snapshot runtime pinning, TestFlight upload (mark as unverified until
    enrollment).
- [x] Machine toolchain in dotfiles, the only dotfiles change:
  - add `xcodegen` (and `pymobiledevice3` via dotfiles' usual Python tool installer) to the
    Brewfile or equivalent manifest;
  - add `scripts/install-xcodes.sh`, which fetches the pinned signed `xcodes` release binary
    to `~/.local/bin`.
  Before editing, run `rd agents` and `git -C ~/SourceRoot/dotfiles status`. If dotfiles is
  busy or dirty, commit only your own paths. Push dotfiles. No global CLAUDE.md, rules or
  skills changes.
**Left behind:** All four steps shipped. `make check` is green (exit 0; no Swift in the repo yet, so nothing Swift is gated), no `/review` run: the
diff is a rule, vendored upstream files and docs, plus a small dotfiles script that was exercised by hand (happy path, checksum
mismatch, signature check, all in a temp `HOME`). **Rule:** `.claude/rules/swift.md` (67 lines, lazy `paths:`). The build-setting
spellings are verified against the 27.1 `Swift.xcspec` and a green `xcodebuild`: `SWIFT_VERSION=6.0`, `SWIFT_STRICT_CONCURRENCY=complete`,
`SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` (values `nonisolated | MainActor`), `SWIFT_APPROACHABLE_CONCURRENCY=YES`; Wave 7 should still
record them in TDD §6. The SwiftPM spelling `.defaultIsolation(MainActor.self)` in the rule is from SE-0466, not yet compiled.
**Skills:** `swiftui-pro`, `swift-concurrency-pro`, `swift-testing-pro`, `swiftdata-pro` in `.claude/skills/` with their MIT LICENSE; pins and the
update procedure are in `.claude/skills/VENDORED.md`. The three siblings live in their own repos (`twostraws/Swift-*-Agent-Skill`), not in
`Swift-Agent-Skills`, which is only a link directory. **apple-dev:** `.claude/skills/apple-dev/SKILL.md`. Run on the mini against a throwaway XcodeGen app
(deleted): `xcodegen`, `xcodebuild build/test/-only-testing/archive` (unsigned), `simctl` boot, `bootstatus -b` (40 s cold), install, launch, `io screenshot`
(glass pill rendered), `openurl`, `push`, `devicectl list devices`, the `mobilebuildmcp@2.7.1` CLI (`build-and-run`, `snapshot-ui`, `screenshot`), and
`pymobiledevice3` help/`usbmux list`. Findings: `simctl push` needs notification permission first (`UNErrorDomain 2003`); `snapshot-ui` right after
boot or launch times out, wait ~8 s; `mobilebuildmcp --style minimal` and `MOBILEBUILDMCP_SENTRY_DISABLED=true` work (Wave 8's `scripts/mbm`).
**Marked unverified in the skill:** signed archive and `-allowProvisioningUpdates`, `security set-key-partition-list`, TCC with a stable identity, TestFlight
upload, `devicectl` install/launch and `pymobiledevice3` screenshot on a real phone, `tap`/`type-text` (the scratch app had no controls), runtime
installs (both 27.0 and 27.1 were already present), Live Activity push through `simctl`. **Dotfiles** (commit `465eae1`, pushed; only my paths, the tree was
clean): `Brewfile` gained `xcodegen`; `scripts/install-xcodes.sh` (pinned 2.1.0, sha256 of the release zip plus the Developer ID team check,
idempotent); `make _setup-tools` runs it and installs `pymobiledevice3==11.45.0` as a uv tool (there is no brew formula and no existing Python tool
installer, so it follows the fallow/ocr pin pattern). The mini now has `xcodegen`, `xcodes` 2.1.0 and `pymobiledevice3` 11.45.0. Not done on purpose:
`swiftlint` (the plan names only `swift format`); `rules/apple.md` and `rules/server.md` (Wave 8); an AGENTS.md index of the new rules and skills (Wave 8
rewrites it). `security find-identity` shows 0 codesigning identities on the mini; Wave 7's simulator builds do not need one (`CODE_SIGNING_ALLOWED=NO`).

## Wave 7 — Apple monorepo scaffold            <!-- status: done -->
Xcode 27.1 is installed on the mini (`xcodebuild -version`). Gate locally *and* on the
`apple.yml` CI run (`gh run watch`). If the simulator runtime is still missing, install it
with `xcodes runtimes install`. Follow `.claude/rules/swift.md` and the vendored
`swiftui-pro` / `swift-concurrency-pro` / `swift-testing-pro` skills from Wave 6.
- [x] `apple/project.yml` (XcodeGen 2.46+, `brew install xcodegen` if missing): targets
      `Iris`, `IrisWidgets`, `IrisNotifications`, `IrisMac`. Bundle ids, App Group
      `group.com.jkrumm.iris`, entitlements, Info.plist keys (`UIBackgroundModes: audio`,
      `NSSupportsLiveActivities`, `NSMicrophoneUsageDescription`, `LSUIElement` for Mac),
      iOS/macOS 26.0 minimum, Swift 6 mode, and MainActor default isolation for the app
      targets. **Verify the build-setting spelling against the installed toolchain or
      the CI image, and record it in TDD §6.** `.xcodeproj` is gitignored.
- [x] Local packages `apple/Packages/{IrisCore,IrisCapture,IrisUI,IrisTelemetry}` with
      their public interfaces stubbed per TDD §4–§8:
  - `IrisCore`: models, an API client, an SSE parser, and decoding tests over every
    `contracts/fixtures` file;
  - `IrisCapture`: protocols for `AudioSessionController`, `RouteManager`,
    `SegmentRecorder` and `Outbox`, plus `FakeCapture`, with segment-rotation and outbox
    state-machine tests on fakes;
  - `IrisUI`: `Theme` generated from basalt-ui tokens by a script, plus a swift-snapshot-
    testing setup with one reference;
  - `IrisTelemetry`: a buffer plus a relay exporter.
- [x] Thin app targets that compile and launch to a placeholder history (fed from fake
      data). The widget extension has a placeholder Control and Live Activity; the
      notification extension has a placeholder card. The Mac target is a MenuBarExtra
      placeholder.
- [x] `.swift-format` + `swift format lint --strict`, and Make targets `generate`,
      `check-apple` (lint, `swift test` per package, `xcodebuild build` of all schemes for
      the simulator), `snapshots` (`RECORD=1`), and `uitest`. Add
      `.github/workflows/apple.yml` on `runs-on: xcode-27` (TDD D14; fall back to `macos-26`
      only if the image queues for more than 30 min). `check-apple` joins `make check` when
      `xcodebuild` exists locally.
**Left behind:** All four steps shipped, `make check` is green locally (it now includes `check-apple` wherever `xcodebuild` exists), and
the `apple.yml` run on the hosted `xcode-27` image went green on its first push (no queueing; check-apple, snapshots and UI smoke, about
12 min). `make snapshots` and `make uitest` also pass locally. `/review` ran through the `agw review` CLI (the MCP failed to connect):
4 blockers, all in capture/telemetry (reentrant `stop()`, tap leaked by a failed start, a repeated `finishMemo` resurrecting a completed
memo, an unserialized telemetry crash-file rewrite), all fixed with regression tests; the re-review approved with 5 optional notes
(teardown seam, a bounded dedupe window of 512 completed memos, file splits). **Layout:** `apple/project.yml` (XcodeGen 2.46; targets
`Iris`, `IrisWidgets`, `IrisNotifications`, `IrisMac`, `IrisUITests`; schemes `Iris`, `IrisMac`; bundle ids, App Group, entitlements,
Info keys per the plan; no team id tracked, signing is injected per build), thin targets in `apple/{Iris,IrisWidgets,IrisNotifications,
IrisMac}`, UI smoke in `apple/Tests/UITests`, packages in `apple/Packages/`, tooling in `apple/tools/` (Bun, `basalt-ui` pinned 2.29.0,
`bunfig.toml` sets `peer = false`, so the install is 12 MB). Build settings (`SWIFT_VERSION 6.0`, `SWIFT_STRICT_CONCURRENCY complete`,
`SWIFT_DEFAULT_ACTOR_ISOLATION MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY YES`) are recorded in TDD §6; all schemes build warning-free.
**Packages (tests on the macOS host):** `IrisCore` 47 tests plus 54 fixture cases (every `contracts/fixtures` file decodes and re-encodes;
a new fixture without a mapped Swift type fails the suite), `APIClient` + `URLSessionAPIClient` + `FakeAPIClient`, `SSEParser`/`ServerEvent`,
`MemoAttributes` (iOS only); `IrisCapture` 58 (protocols, `SegmentRotator`, `OutboxStateMachine`/`Outbox`, `TakeLifecycle`, `FakeCapture`, AVAudio
adapters compile-checked on iOS only); `IrisTelemetry` 46 (`TelemetryBuffer`, `FileTelemetryStore` actor, `RelayExporter`, `Tracer`); `IrisUI`
4 plus 1 snapshot (`Theme` generated by `bun apple/tools/gen-theme.ts`, `--check` is a CI gate; `RouteChip`). **Make targets:** `generate`,
`theme`, `lint-apple`, `test-packages`, `build-apple`, `check-apple`, `snapshots` (`RECORD=1` re-records, forwarded as `TEST_RUNNER_RECORD`),
`uitest`. **Pinned simulator: iPhone 17, iOS 27.0** (`SIM_NAME`/`SIM_OS` in the Makefile), recorded and verified on the mini and on CI; the
snapshot references capture content, color, type and layout but NOT the glass layer (no host app, so it does not render in a snapshot).
Also fixed: `scripts/public-guard.ts` crashed on the two tracked symlinks to directories in the vendored skills, which had turned CI red since
Wave 6. **Carry forward:** (1) `LiveActivityPhase` has only the server phases (`processing|needsRoute|done|failed`); the client-local
`recording|paused|uploading` of TDD §4 are missing and the placeholder Live Activity shows the timer under `processing`: R1 must add them
(the server contract and fixtures stay as they are, so decide whether it is a client-only enum). (2) `IrisCapture`, `IrisUI` and
`IrisTelemetry` do not depend on `IrisCore` yet (they define `MemoID`, uploader and transport ports locally); R1 wires them. (3) `POST
/v1/telemetry` does not exist on the server; the client payload is a proposed shape documented on `TelemetryBatch`. (4) Not device-verified:
the AVAudioEngine recorder, both interruption notification paths (`didBecomeInactive`/`resumptionRecommendation` are iOS 27 only, with an
`interruptionNotification` fallback for 26), `.bluetoothHighQualityRecording`; ControlWidget, Live Activity, Dynamic Island, notification card
and the Mac panel compile but were never rendered. (5) Telemetry's crash file needs a file-protection class (until first unlock) set by the app;
the outbox persists absolute file URLs and never deletes uploaded segment files (app policy, R1). (6) The recorder does not consult
`RouteManager` rules; a coordinator applies them and calls `rotate(for: .micSwitch)` (R1/R2). (7) No `.xcstrings` catalog in the app targets yet
(English defaults only); `IrisUI` has en/de. (8) TDD §3 is still stale vs the server (Wave 5 list); Wave 8's doc pass amends it. (9) `xcodebuild`
leaves `apple/.dd` and per-package `.dd`/`.build` (all gitignored).

## Wave 8 — Iris agent tooling + verification harness            <!-- status: done -->
- [x] No MCP (TDD D17). Add `scripts/mbm`, a wrapper around a pinned
      `npx -y mobilebuildmcp@<version>` CLI (`--style minimal`, Sentry telemetry off), plus
      Make targets: `sim` (boot the pinned simulator + `bootstatus -b`), `run-sim`
      (build, install, launch), `screenshot` (writes to `.artifacts/`) and `ui-snapshot`.
      Every one of them has actually been run against Xcode 27.1 on the mini.
- [x] `.claude/rules/apple.md` (paths `apple/**`): Iris invariants only (generic Swift
      lives in `.claude/rules/swift.md`): never `AVAudioRecorder`, the segment rotation and outbox
      contract, the Live Activity 4 KB / headline ≤ 60 rules, contract fixtures as the API source
      of truth, `FakeCapture` for UI tests, no real hosts in fixtures. Add
      `.claude/rules/server.md` (paths `server/**`) the same way. Each points at its TDD section.
- [x] Own skills (TDD §10): `iris-server`, `ios-verify`, `device`, `memo-debug`,
      `apple-capture-notes`. Each has a short SKILL.md whose commands were actually run (or,
      without local Xcode, marked `unverified until Xcode` in one line).
- [x] `fixtures/audio/de-90s.m4a` already exists (Wave 4, 96 s, audio-gateway TTS); keep it,
      and document how it was generated. Used by `make e2e` and `make smoke`. Write
      `docs/spikes/device-checklist.md` (TDD §9, hardware-only rows) and the S1–S3 spike
      briefs in `docs/spikes/`.
- [x] Rewrite AGENTS.md for the monorepo: layout, the full Validate matrix, the public-repo
      rule, the Xcode/CLI tooling setup, an index of the repo's skills and rules, Gotchas. Point it at TDD/PRD.
**Left behind:** All five steps shipped. **Tooling:** `scripts/mbm` (pinned `mobilebuildmcp@2.7.1`, `--style minimal`, `MOBILEBUILDMCP_SENTRY_DISABLED=true`) and the Make targets
`sim`, `run-sim`, `screenshot` (`NAME=`), `ui-snapshot` (`UI_SETTLE`, default 8 s), all run on the mini against Xcode 27.1 on the pinned iPhone 17 / iOS 27.0
(the UDID is resolved from `SIM_NAME`/`SIM_OS` with `simctl -j` + `jq`). `run-sim` builds, installs and launches with `-IrisFakeCapture`; the screenshot shows the
fake-data History. `snapshot-ui` lists the rows by `history.row`; `tap` navigated to the detail (`BackButton` in the next snapshot) only with
`--element-ref` and `--post-delay 2` (the first tap without the delay reported success but did not navigate). `type-text` and `swipe` are not driven (no
text field yet). **Rules:** `.claude/rules/apple.md` (34 lines, `apple/**`) and `.claude/rules/server.md` (27 lines, `server/**`), each pointing at its TDD
section. **Skills** in `.claude/skills/`: `iris-server` (`make e2e` run), `ios-verify` (every target run), `device` (`devicectl list` and `usbmux list` run, the
rest marked `unverified until a phone is paired`), `memo-debug` (health, memo list, memo detail run against the live loopback instance with the smoke token;
the HyperDX query is from Wave 4 and `retry` is unverified live, both said so in the skill), `apple-capture-notes` (summary of TDD §4 and the two research notes; every
Apple row is un-device-verified and says so; the capture/session/interruption/EU rows are TDD claims with no research note behind them). **Fixtures and spikes:**
`fixtures/audio/README.md` documents how `de-90s.m4a` was made (audio-gateway TTS, voice `Charon`, synthetic; the recipe was re-run with a short input, the original script
was not kept), `docs/spikes/{README,S1-lock-screen-start,S2-mic-switch,S3-apns-live-activity,device-checklist}.md`. **Docs:** AGENTS.md rewritten for the monorepo
(layout, rules and skills index, tooling, Validate matrix, public-repo rule, server details kept, Apple gotchas); TDD §3 amended to the shipped code (data model, HTTP API,
modules, pipeline notes, token refresh, mbm env var), planned items marked as planned. Gate: `make check` green (see the Wave-8 commit), no `/review`: the diff is docs,
rules, skills, a six-line wrapper and four Make targets, each run by hand. Carry forward: (1) `make run-sim` and `screenshot` leave the simulator booted (`xcrun simctl shutdown` when done); (2) Wave 5's carry-forward items 2-5 (composition dedupe,
`MEMO_NEEDS_ROUTE`, `+faststart`, lint warnings) and Wave 7's items (LiveActivityPhase client phases, package dependencies on `IrisCore`, `POST /v1/telemetry`, `.xcstrings`)
remain open for the fleet. Stopped: the next wave (9, mockups) is spawned by the orchestrator tab.

## Wave 9 — UI mockup round            <!-- status: done -->
- [x] `docs/design/mockups/`: static HTML using the basalt-ui tokens (the same values as
      `IrisUI/Theme`), styled to read as iOS 26 Liquid Glass. Surfaces: History, Memo detail
      (step timeline, cost, retry), Record (timer, waveform, mic picker, mode/tab picker),
      Live Activity (recording / processing / done / needs-route, Lock Screen + Dynamic
      Island), the notification card, the Mac panel. Use realistic German and English
      sample content.
- [x] Render each surface to PNG (chrome-devtools screenshot at device sizes), upload via
      `/img` as private presigned links, and list them in `docs/design/README.md`.
- [x] Stop here: the owner reviews the mockups. Write "stopped: owner reviews mockups;
      then the fleet starts R1 from the Fleet backlog" into **Left behind** and do not
      spawn.
**Left behind:** All three steps shipped; `make check` is green when run directly (exit 0, incl. `check-apple`). The `agw check` MCP run failed only
in `xcodegen generate` ("Couldn't find current username", a sandbox artifact of the gateway worker), so the green is from the direct run. No `/review`:
the diff is static HTML/CSS/JS, a token generator and a render script, nothing in the product paths. **Where:** `docs/design/mockups/*.html` (open with
`?scheme=light|dark&v=<variant>`), `tokens.css` (generated from `BasaltTokens.generated.swift` by `gen-tokens.ts`, so the values equal `IrisUI/Theme`),
`mock.css` (glass approximation, only on floating controls), `la.css`, `mock.js` (icon sprite, seeded waveforms), `docs/design/render.ts`, `make mockups`.
**Surfaces (23 renders at 2x):** History (light, dark), Memo detail (done light and dark, failed dark: timeline, duration bars, cost, retry), Record (take light
and dark, mic sheet, mode and tab sheet), Lock Screen (idle with the Control, recording, processing, done in dark and light, needs-route), Dynamic Island
(compact and expanded, four states), notification card (done light and dark, needs-route), Mac (floating panel light and dark, menu-bar window, native
notification). Sample content is German and English and reuses the fixture memo. **Links:** all 23 PNGs are uploaded with `imgcli private`, 7-day presigned
links (expire 2026-11-03). **The repo is public, so the links are NOT in `docs/design/README.md`** (a presigned URL carries the real bucket host and signature,
which the public guard and the repo rule forbid): they sit in the untracked `docs/design/links.local.md` on the mini; the README lists the surfaces and
renders and says how to re-issue. PNGs are gitignored (`docs/design/renders/`, regenerate with `make mockups`). Deviations: rendered with headless Chrome CLI
instead of the chrome-devtools MCP (same engine, scriptable for 23 shots; it exits non-zero after a virtual-time screenshot, so the file is the success
signal). Mockups are approximations: the Liquid Glass is CSS blur plus a rim, SF Pro comes from the host font stack, and nothing is device-verified.
Open design questions for the owner are at the end of `docs/design/README.md`. Stopped: owner reviews mockups; then the fleet starts R1 from the Fleet backlog.

## Fleet (from 2026-10-27 evening)

The foundation chain (Waves 1–9) is complete. The fleet takes over: a mother (`docs/waves/handoff/mother.md` is its
memory) turns the backlog below into Wave 10+ sections, one active at a time, each executed by a lead that fans out
workers. The mother writes the next wave here.

**Status: resumed 2026-10-28** (owner; runs through the night). Waves 10–14 are done; Wave 15 is active. Quota is the
constraint: Max accounts only, wait for a reset when all are walled, never IU API tokens. Mother memory: `docs/waves/handoff/mother.md`.

**Fleet gate (every wave):** each worker runs its cheap check; the lead runs `make check` at every merge (`rd merge`),
`make e2e` for server changes, and `agw review` (CLI) on every non-docs diff with findings resolved. Server changes are
pushed to master, the poller deploys, then `make verify` + `make smoke` on the mini. Apple changes gate on `apple.yml`.
API changes run `make contracts` and update fixtures, and the same brief carries the Swift `IrisCore` follow-up (models + client
call) so `apple.yml` stays green. TDD and AGENTS.md change in the same commit as the code they describe.

## Wave 10 — Design round 2 ∥ R2 routing core (server)            <!-- status: done -->
Backlog 0 and the first half of backlog 4. Two tracks on disjoint files, fanned out in parallel: **A** owns
`docs/design/**` (plus the `mockups` Make target if it must change), **B** owns `server/**`, `contracts/**`, `scripts/**`.
Inside B, B1 lands before B2/B3 are briefed (every new port wires through the composition B1 creates).
- [x] **A. Design round 2** (`docs/design/feedback-round-1.md` is binding). Changed surfaces: memo detail (less shadow;
      scrubbable player with a 10 s back button; the step waterfall, each bar starting where the previous ended and marked
      faster/slower than that step's median, collapsed by default with an expanded variant; cost collapsed; no trace id),
      Settings → Diagnostics (trace id with copy, the hide-cost-on-Lock-Screen toggle), Dynamic Island (mic-swap icon button,
      pause kept, two memos in a row), notification (smaller side-by-side actions), Mac notification with Reply, Record
      (tab chip de-emphasized). New surfaces: Chat mode (mode choice + the answered thread), typed-memo composer, History
      filters (route, state), Stats (volume per route per day/week, trends), Threads view (list, one thread rendered as
      markdown, hold-to-talk). Light and dark where round 1 had both. Render with `make mockups`, upload private 7-day links via
      `/img`, list them only in the untracked `docs/design/links.local.md`, rsync the gallery to
      `iumac:/tmp/iris-mockups.html` and `ssh iumac open` it. `docs/design/README.md` gets a round-2 section and the open
      questions. The owner's review is async: do not wait for it.
- [x] **B1. Composition dedupe + Wave 5 debt:** one composition used by both `index.ts` (production) and `compose-fakes.ts`
      (`IRIS_FAKES=1`), so a new port is wired once; `+faststart` on the ffmpeg concat; clear the oxlint warnings.
- [x] **B2. Routing core** (TDD §3 Pipeline steps, step 3): a non-auto mode wins; the prefix parser ("journal|tagebuch",
      "an hermes|hermes", "tab <name>", first 6 words, case- and diacritic-insensitive, prefix stripped from the transcript);
      otherwise `decide` through agw behind a `Decider` port (adapter + fake), state = transcript (first 4k chars) + herd
      summary; confidence ≥ 0.8 → `routed`, else `needs_route`. Only destinations with a registered `act` adapter are
      choices; a prefix or mode naming an unregistered one (journal/herdr until Wave 11) parks at `needs_route` with the
      reason. A `route_decisions` table (append-only migration) records every outcome: source (mode/prefix/decide/answer/
      correction), destination, tab, confidence, model, cost.
- [x] **B3. Answers and corrections:** `POST /v1/memos/:id/route {destination, tab?}`: from `needs_route` it routes and
      drives on; after `act` it records a correction only (no re-act). The `MEMO_NEEDS_ROUTE` alert category and the
      needs-route Live Activity content state on the APNs notifier. Contracts, fixtures, manifest, SSE event coverage.
- [x] Deploy and prove it: `make verify` + `make smoke` on the mini after the poller deploys (the smoke memo must still
      reach `notified`; pin `--mode hermes` in smoke if `decide` could route it elsewhere). TDD §3 (state machine, pipeline,
      data model, HTTP API) and AGENTS.md amended to the shipped behaviour.
**Left behind:** All five steps shipped as PRs #1–#4 (+ #3 design), each merged by the train after a green full `make check`; `agw review`
(CLI) on #1, #2 and #4 with findings resolved (#3 is docs/static HTML, no review). Deployed `cc19d4c`: `make verify` healthy, `make smoke` `notified`
(~11 s, route `default`). CI `check` green on `cc19d4c`; `apple.yml` was still running at close-out.
**A (design round 2, #3):** 41 `r2-*` renders (both schemes where round 1 had both) of every changed and new surface; 7-day private links (expire
2026-11-03) only in the untracked `docs/design/links.local.md`; gallery at `iumac:/tmp/iris-mockups.html` (+ `/tmp/iris-mockups/`), opened on the
MacBook. `docs/design/gallery.ts` builds it. README "Round 2" lists every feedback item and the open questions for the owner (Mac hotkey placeholder,
cost toggle placement — the worker suggests a Settings group, side-by-side notification actions need a device check, Stats colour for tab memos,
waterfall 15 % threshold / last-30 median). One stray private image object from a test upload (r2-detail-light) remains; delete it with backlog 10.
Owner review is async and pending.
**B1 (#1):** `server/src/compose.ts` (`compose()` + `fakePorts`) is the only place a port is chosen; `compose-fakes.ts` is gone; `index.ts` is
process concerns only. `+faststart` on the concat. oxlint is at 0 warnings over `server/src` and `scripts`.
**B2 (#2):** `server/src/routing/` (prefix parser, `route()`), `Decider` port + `adapters/agw-decider.ts` (shares the agw job runner with triage),
destination registry (`Destinations`, `isDestinationName`, `hasChoice`), act dispatches on `memo.route`, `route_decisions` (migration 5). Deviations from
the brief, all deliberate: decide uses the 30 min agw hang guard, not 30 s (the agent-limits rule; TDD timeout row amended); a decide infrastructure
failure FAILS the route step (retry recovers it) and only refusal / unknown destination / herdr without a live tab / low confidence / no decider park;
`memos.transcript` stays raw and `deliveredTranscript` strips a spoken prefix for act and summarize (retry-safe); with fewer than two registered
destinations the router routes to the only one (source `default`, no spend), so production is hermes-only until Wave 11; with no destination
registered neither route nor act has a handler (memo waits at `transcribed`). Known production effect until Wave 11: an auto memo opening with
"journal"/"tagebuch"/"tab X" in its first six words parks at `needs_route` ("journal not available").
**B3 (#4):** `POST /v1/memos/:id/route` (answer from `needs_route` → 202 + drive; after act → correction only, 200; else 409; unregistered → 400;
`tab` iff herdr), memo wire gains optional `routeReason` / `routeSuggestion` (derived from the latest decision, no migration), `MEMO_NEEDS_ROUTE`
alert via `Notifier.needsRoute` (the Live Activity part already came from `bindPhaseUpdates`), `isCorrectable()` in `memo.ts`, contracts + fixtures +
manifest, e2e probe (answer + correction). Found and fixed on the way: Elysia `t.UnionEnum` defaults a missing value to its first member, so
`POST /retry {}` used to retry from `ingest`; `RetryBody` and `RouteBody` now set `default: undefined` (400). The train caught the Swift side
lagging the contract: `IrisCore` now has `RouteRequest`, `RouteDestination`, `routeMemo`, `Memo.routeReason/routeSuggestion`.
**For Wave 11:** resolve spoken tab names (prefix `tab <name>`, mode `tab`) against the live herd before act (today they are stored unchecked; the
decide path stores herd ids); `herdr` and `journal` join the registry in `compose()`, which turns `decide` on (two or more destinations). Lead
lessons: `rd merge` fails on a draft PR (`gh pr ready` first); `agw review` CLI prints only the summary — the findings are in
`GET /api/jobs/<id>` `.job.result`; a contract change must include the Swift `IrisCore` follow-up in the same brief.

## Wave 11 — R2 destinations, Chat mode, typed memos (server)            <!-- status: done -->
The second half of backlog 4. Chat reading **confirmed by the owner 2026-10-27**: Chat = a Hermes session (`source` marks it
as chat) opened with a no-side-effects system message, its answer stored as the reply and threaded.
- [x] **Journal destination:** write `brain/Inbox/<YYYY-MM-DD>-<slug>.md` (TDD §3 act table) under the brain-sync lock,
      commit and push per `brain/docs/brain-access.md`; templated summary (no model spend). Its smoke must not leave test
      notes in the real brain (a fake brain dir in e2e; on the mini, a dedicated smoke path or a cleanup the lead defines).
- [x] **herdr destination:** `pane.send_text` + `send_keys Enter` on the resolved tab; a vanished tab → `needs_route`;
      templated summary. Spoken tab names (prefix `tab <name>`, mode `tab`) are resolved against the live herd in `route`
      (Wave 10 stores them unchecked); no match → `needs_route` with the reason.
- [x] **Chat mode:** mode `chat` per the confirmed reading; thread upsert (the `threads` table if it is not there yet).
- [x] **Typed memos:** create a memo from text (skips `transcribe`), same modes and pipeline; contract + fixtures.
- [x] **agw `caller`:** agent-gateway accepts a `caller` field and attributes usage to it (its own commit in that repo);
      iris sends `caller: iris` on decide/triage.
- [x] Deploy, `make verify` + `make smoke`, one real memo per new destination through production; TDD and AGENTS.md amended.
      Registering journal + herdr in `compose()` turns `decide` on, so `make smoke` pins `--mode hermes` (an auto smoke memo
      must never land in the real brain or a live tab). The agent-gateway change: check `rd agents` for a live agent in that
      checkout first and work in a worktree if one is there.
**Left behind:** Six iris PRs, each merged by the train after a green full `make check` and an `agw review` (CLI) with blocking
findings resolved: #5 journal, #6 herdr, #7 typed memos, #8 journal runner flake, #9 wiring, #10 chat. agent-gateway `2f6bb11` (`caller`)
was pushed direct to master (that repo forbids PRs), reviewed on its branch, and deployed with `make deploy` (verify OK). Iris `f5da34c` is
deployed: `make verify` healthy, `degraded: []`, `make smoke` `notified` (hermes pinned). Real production memos: journal (a note committed and
pushed, then removed by the lead with `journal: remove the Iris Wave 11 test note` under the brain-sync lock), chat (a `chat` thread, reply
"Canberra."), herdr (prefix `tab irissmoke` into a scratch shell tab the lead created and closed; the command ran), and auto (`decide` →
hermes at 0.99). The decide and triage agw jobs carry `caller=iris`. The production DB was backed up before the threads migration:
`~/.iris/data/iris.db.pre-w11-threads.bak` (delete it once Wave 12 has run cleanly).
**Journal (#5, #8, #9):** `adapters/journal.ts`. The lock follows brain-sync.sh's protocol exactly: the `pid` file, a live/EPERM holder waits,
a dead pid or a pidless lock at least 60 s old is reclaimed, and the lock is released only while the pid is still ours. Only the note's own
path is committed. The push runs outside the lock, bounded and fail-soft. The git runner kills the process group on timeout and tolerates
EPERM from a zombie group leader; that macOS behaviour was the train flake. The note is written atomically (tmp + `link`), and a retry is
idempotent through the `memo:` frontmatter. Umlauts are spelled out in the slug (ä→ae).
**herdr (#6):** `createHerdrDestination` sends `pane.send_text` and then `pane.send_keys ["enter"]`, verified against herdr 0.9.3. It targets
the tab's agent pane, or the only pane. Deliveries to one pane are serialised. `act` may now park (`routed → needs_route`): a vanished tab, a
`pane_not_found` error or a herdr route without a tab writes a decision row that reuses the routing source (no migration). Spoken tab names
match a label or a repo case- and diacritic-insensitively, and only one word is captured, so multi-word labels cannot be spoken (in TDD). Mode
`tab`, or a default route to herdr, takes the single live tab, else parks with "which tab?". The `summarize` handler is always present:
journal and herdr use templates, and a hermes memo with no summarizer now FAILS at summarize instead of waiting at `acted`. A retry from `act`
after a failed Enter re-types the transcript (AGENTS.md gotcha).
**Typed (#7):** `POST /v1/memos/text {id, mode, startedAt, text}` creates the memo in `transcribed`, max 20 000 code points, and replays are
idempotent. The memo wire carries an explicit `typed`. `/audio` answers 409 and a retry from `transcribe` answers 400. Found and fixed on the
way: a missing `mode` on `POST /v1/memos` was silently accepted as `auto` (the `t.UnionEnum` default trap again); it is now 400.
`send-memo.ts --text`, Swift `createTextMemo` / `Memo.isTyped`.
**Wiring (#9):** `compose()` registers journal (`BRAIN_DIR`, exported by launch.sh when the checkout exists), herdr (`HERDR_SOCKET`, only when
the socket exists) and hermes, so `decide` is live. Fakes register all three. e2e probes cover journal, tab, decided, typed, chat and route.
**Chat (#10):** mode `chat` maps to hermes. A per-turn `system_message` carries the no-side-effects policy, and the session is created with
`source: "iris-chat"`, BUT Hermes' api_server rewrites any source not on its allow-list to `api_server`. Hermes therefore cannot see the chat
marker; `threads.kind` is the marker (documented in TDD). The `threads` table and `memos.thread_id` come from migration 6, which backfilled
existing hermes memos. `Delivery.thread` names the thread and `act` persists it. Swift `MemoMode.chat` (+ a tolerant `.unknown`) and
`Memo.threadId`. Not built: continuing a thread (`threadId` on create), which is R3.
**For the next wave:** thread continuation and the `GET /v1/threads` endpoints (R3, backlog 7); the multi-word spoken tab names. The owner may
want Hermes' source allow-list widened for `iris-chat`, which would be a change in the third-party hermes-agent. Lead lessons: rebase
conflicts between parallel workers sharing `memo.ts` and `TDD.md` hunks never materialised (the train's rebase handled them); `mini-deploy`
waits for the CI `check` run, so `make deploy` right after a merge only logs "waiting for CI". Watch `gh run watch` first. The agent-gateway
check has one pre-existing mini-only failure (`GIT_DENY_CREDENTIALS_ENV` vs the global osxkeychain helper), which reproduces on a clean master.

## Wave 12 — R3 server: threads, search + filters, stats, telemetry relay            <!-- status: done -->
The server half of backlog 6 and 7 plus Wave 7's server carry-forward. No phone and no design answer needed: every item is
an API the R3 screens (Wave 13+) consume. Each contract change carries its Swift `IrisCore` follow-up (models + client call +
fixture decode tests). Disjoint tracks where the files allow; the lead sequences anything touching `memo.ts` / `schemas.ts`.
- [x] **Threads API:** `GET /v1/threads` (newest `updated_at` first, `kind` filter, cursor) and `GET /v1/threads/:id` (the thread
      row + its Iris memos + the Hermes session transcript as markdown messages, read from Hermes; Hermes down → the Iris part with
      a flag, not a 503). Continue a thread: `threadId` on `POST /v1/memos` and `/memos/text` targets that Hermes session (a chat
      thread re-sends the no-side-effects `system_message` every turn, TDD §3); unknown thread → 404.
- [x] **History search + filters:** `GET /v1/memos` gains `q` (transcript + headline, SQLite FTS5 or LIKE: the lead decides and
      writes why in TDD), `route` and `state` filters, and keeps `needs_route` memos pinned first (PRD R-HIS-1). Cursor stays stable.
- [x] **Stats:** `GET /v1/stats?days=<n>` — counts per route per day, totals per week, median step durations (the memo detail
      waterfall compares against them, round-2 design), cost per route. Pure SQL aggregates over existing columns, no new spend.
- [x] **Telemetry relay** (TDD §8, Wave 7 carry-forward): `POST /v1/telemetry` takes the Swift `TelemetryBatch` (finalize the shape)
      and forwards spans/logs through the existing OTLP exporter with the memo trace id; bounded body, auth as every `/v1` route.
- [x] **Housekeeping:** `actions/checkout` (and any other Node 20 action) bumped in `check.yml` / `apple.yml`; multi-word spoken tab
      names if it stays small (else Left behind); after this wave's deploy runs cleanly, delete `~/.iris/data/iris.db.pre-w11-threads.bak`.
- [x] Deploy, `make verify` + `make smoke`, probe each new route against production with the smoke token; TDD §3 (HTTP API, data
      model, "planned, not built" list pruned) and AGENTS.md amended.
**Left behind:** Five PRs, each landed by the train after a green full `make check`: #11 housekeeping, #13 telemetry, #15 threads, #12 stats,
#14 search. `agw review` (CLI/job API) on #12–#15, blocking findings resolved; #11 is a workflow-only version bump (no review: verified each action's
current major and `node24` runtime by hand). Deployed `482883d`: `make verify` healthy, `degraded: []`, `make smoke` `notified` (hermes pinned).
Production probes with the smoke token: threads list/detail/`kind=chat`/404, a typed chat continuation into the existing chat thread (reply
"Sydney." after "Canberra.", detail shows four messages), unknown `threadId` → 404, `q` (umlaut-folded "bestatigt" matches), `route`/`state`
filters, bad state → 400, `stats?days=7` (13 per-step-and-route medians), `days=0` → 400, telemetry 202/401/413 and a `telemetry.relayed` log line.
DB backed up before migration 7 at `~/.iris/data/iris.db.pre-w12-fts.bak` (delete after Wave 13 runs cleanly); the w11 backup is deleted.
CI `check` green on `482883d`; `apple.yml` was still queued on the hosted xcode-27 runner at close-out (the train ran `check-apple` locally on every merge).
**Owner round 2 (binding, `docs/design/feedback-round-2.md`), applied mid-wave:** Iris owns chat data. `GET /v1/threads/:id` is built from Iris's
own memos (per turn: transcript → `user`, `reply_text` → `assistant`, with `memoId`, `createdAt`), Hermes is never read; no Hermes patch. Stats
medians are per step AND route with `samples` (n); the client owns the minimum-n threshold (no `minSamples` on the wire, TDD says why).
**Threads (#15):** `sqlite-threads.ts` (`ThreadStore`, composed into the memo store), `http/threads.ts`. A continuation (`threadId` on either create
route) skips session create and `decide`, is forced to hermes, re-sends the chat `system_message` when the thread's `kind` is chat, keeps `thread_id`
across a retry; replay with another `threadId` → 409. Follow-ups: `getThread` reads step records per memo (N+1, unbounded); a continuation is
accepted while hermes is unregistered and fails at route (retry recovers); concurrent turns into one Hermes session are not serialised.
**Search (#14):** FTS5 (bun:sqlite ships it on the mini), external content over view `memo_search`, `unicode61 remove_diacritics 2`, quoted
prefix terms ANDed (TDD has the why), migration 7 with triggers + backfill. `pinned` (every `needs_route` memo matching the filters, cap 50, first
page only); `items` never holds one, so the seq cursor is stable. A memo answered between page fetches can repeat: clients de-duplicate by id
(documented; `HistoryModel` does). Behaviour change for any client reading only `items` (none shipped). Follow-ups: no signal when the 50 cap
truncates, `listMemos` mixes filter SQL and the pinning policy, tri-state `ftsMatch`, positional SQL binding.
**Stats (#12):** `sqlite-stats.ts` (`StatsStore`), days/weeks bucketed in JS local time (bun test forces TZ=UTC, SQLite follows the system).
Follow-ups: no index on `memos.created_at` / `memo_steps.started_at` (full scan, fine at this scale), the store is built in `index.ts` rather than
`compose()`, and the aggregation could split out of the adapter.
**Telemetry (#13):** `POST /v1/telemetry` reads its own body (401 before any byte, 413 at 256 KiB while streaming, ≤500 records), re-emits OTLP
with `service.name=iris-ios|iris-macos`; exports share the `MAX_IN_FLIGHT` cap (at the cap: rejected without a fetch, counted in
`telemetry.relay_failed`, client still 202). Swift encoder now rounds to the millisecond (it wrote .800 as .799). IrisCore's fixture test skips
the `telemetry.*` schemas, decoded by IrisTelemetry's own conformance test.
**Housekeeping (#11):** `actions/checkout@v7`, `upload-artifact@v7` (setup-bun v2 is already node24). Multi-word spoken tab names NOT built: the
word count of the matched name would have to live on the decision row (`deliveredTranscript` re-strips the prefix in act/summarize without the
herd), which is a schema + steps change; TDD still states one word.
**For the next wave:** R3 iOS screens per round 2 (History is the one list: no Threads tab, a conversation opens the thread view; quick filters;
swipe actions; Stats; typed composer). Server debt above, multi-word tab names. Lead lessons: `rd merge` runs `make check` but not `make e2e` — an
API behaviour change broke the e2e probe only on CI (fixed in `482883d`); run `make e2e` before the train for server-behaviour PRs. Parallel workers
on shared additive files (AGENTS.md, TDD, registry.ts, conformance tests, FakeAPIClient) conflict on every rebase despite named anchors: land one
at a time and resolve the additive conflicts in the lead (fast); briefing anchors did not help. Parallel `xcodebuild` from several worktrees gets
SIGTERMed (twice in the train); rerun. A backgrounded `agw review` CLI stops printing when its shell exits; read `GET /api/jobs/<id>` instead, and
one job returned a degenerate result (`summary: placeholder`) whose single finding was still real.

## Wave 13 — R3 server completion (flags, auto retries, debt) ∥ iOS History shell            <!-- status: done -->
Backlog 4b (minus Pele and speech, which are Wave 14) plus the first slice of backlog 6. Design is binding:
`docs/design/feedback-round-1.md` + `feedback-round-2.md` (round 2 wins). Two tracks: **S** (`server/**`, `contracts/**`,
`scripts/**`, plus the `IrisCore` follow-up for each contract) and **I** (`apple/**` app and `IrisUI`). Wave 12's lessons apply:
land server PRs one at a time and resolve additive conflicts (AGENTS.md, TDD, registry, conformance, FakeAPIClient) in the lead;
run `make e2e` before the train for any server-behaviour PR; only one worker runs `xcodebuild` at a time.
- [x] **S1. Memo flags:** done, favorite, archived, and delete as a soft delete with an undo window, then purge (audio and speech files
      too). Endpoints the swipe actions call, list filters for the quick-filter chips (Favorites, Chats, Needs route; archived and
      deleted hidden by default, an Archived filter shows them), SSE `memo.updated` on every flag change. Contract + fixtures + `IrisCore`.
- [x] **S2. Automatic retries:** transient step failures (5xx, timeout, connection errors) retry twice with exponential backoff before
      `failed`; the attempt count per step is on the memo wire (round 2: the UI shows attempts per step). TDD §3 states it as built.
- [x] **S3. Wave 12 debt:** `getThread` N+1 → one query; a continuation while hermes is unregistered is rejected at create (not a
      route failure); turns into one Hermes session serialised; indexes on `memos.created_at` and `memo_steps.started_at`; the stats
      store composed in `compose()`; `pinned` signals when the 50 cap truncates. Multi-word spoken tab names stay out (Left behind).
- [x] **I1. iOS History shell** (simulator, `-IrisFakeCapture` / fake API client): tabs **History · Stats · Settings** (no Threads tab;
      the freed slot stays empty). History: round-1 rows (route chip · state · headline · relative time), pinned needs-route rows on top
      (tinted), de-duplicated by id across pages, search, **quick-filter chips**, the bottom-sheet filter (route, state), SSE live updates,
      and **swipe actions** wired to S1 (right: done, further right: favorite; left: archive, further left: delete with undo). Stats and
      Settings tabs are placeholders here (Wave 14 fills them). Snapshot tests (light + dark), a UI test of a swipe, screenshots via
      `make screenshot` checked against the round-2 renders.
- [x] Deploy and prove: `make verify` + `make smoke`, production probes of each new route with the smoke token (flag, undo, purge on a
      smoke memo only); `apple.yml` green; TDD and AGENTS.md amended. Delete `~/.iris/data/iris.db.pre-w12-fts.bak` once this deploy runs cleanly.
**Left behind:** Five PRs, each landed by the train after a green full `make check` (S PRs also `make e2e`): #16 flags, #17 retries, #18 debt,
#19 History shell, #20 UI-test fix. `agw review` (job API) on #16–#19, every blocking finding fixed before merge (#16: the purger dropped sweep
errors silently, media routes served a deleted memo; #17: `stop()` during a backoff re-ran the handler, a timed-out agw submit was re-submitted;
#18: `APIErrorCode` lacked `destination_unavailable`; #19: a stale flag completion resurrected a deleted row, a failed load after a filter change
left the old filter's rows and cursor). #20 is a test-only timing fix (no review: two-file diff, `make uitest` green). Deployed `c39eb6a` (server;
#19/#20 are apple-only): `make verify` healthy, `make smoke` `notified`. Production probes with the smoke token: PATCH flags (favorite/done/archived),
`favorite=true` / `archived=true` lists, archived hidden by default, unknown key and `favorite=false` → 400, DELETE → `deletedAt`/`purgeAt` (+10 min),
deleted memo readable, PATCH and `/audio` on it → 409, restore, second restore → 409; purge of a second smoke memo after the window: 404, audio dir
and row gone, `memo.purged` logged; `attempts` on every step, `pinnedTruncated` (false on page 1 and 2), thread detail unchanged, unknown `threadId`
→ 404, both new indexes present (user_version 10). `destination_unavailable` is test-only (hermes is registered in production). DB backed up before
migration 9 at `~/.iris/data/iris.db.pre-w13-flags.bak` (already at 8: S1 had deployed; delete after Wave 14 runs cleanly); the w12 backup is deleted.
apple.yml failed on `63360af` (undo toast expired before the UI test's tap on the hosted runner), fixed by #20 (`-IrisUndoSeconds`); `check` + `apple.yml` green on `225235e`.
**S1 (#16):** columns `done`, `favorite`, `archived_at`, `deleted_at` (migration 8); wire `done`/`favorite`/`archived` + `deletedAt`/`purgeAt`;
`PATCH /memos/:id` (unknown keys 400, parsed by the route: Elysia strips them), `DELETE` (settled states only, idempotent), `POST /restore` (404 past
`purgeAt` even before the sweep, so it never races file removal); purger (`memo/purge.ts`, boot + 60 s, files before rows, thread repointed or
deleted). List `favorite`/`archived`/`kind`; deleted memos hidden everywhere; a done `needs_route` memo is not pinned. Flag events are `memo.updated`
with an internal `flagChange` marker so no `memo.done`/alert/Live Activity push re-fires. `manifest.ts` method enum gained PATCH/DELETE.
**S2 (#17):** `TransientError` (`ports/transient.ts`) with `before_send`/`after_send`; 2 s / 8 s backoff via injected `Sleep`; `act` and agw
submit retry only `before_send`; `memo_steps.attempts` (migration 9) on the wire; `step.retry` log + `memo.retry_wait` span; a retry publishes no
event. Squashed to one commit at merge (its commits reformatted then un-reformatted TDD tables). Follow-up: a hang-guard timeout (decide/triage,
30 min) also counts as transient, so a hung step can take ~90 min before `failed`.
**S3 (#18):** `getThread` in a fixed number of queries; continuation without hermes → 409 `destination_unavailable`; per-thread `createKeyedQueue`
around `deliver` (herdr's per-pane queue reuses it); indexes (migration 10); `compose()` builds the stats store; `pinnedTruncated`.
Review improvements not taken: an unbounded wait in the per-thread queue (a hung Hermes turn holds the thread up to the act timeout).
**I1 (#19):** tabs History · Stats · Settings (placeholders), rows per the render (dot · route · duration, coloured state, headline, grey secondary
line; no cost: the list wire has none), day sections + "n memos today · audio" subtitle (counts the loaded, filtered list), search, chips
(Favorites, Chats, Needs route, Archived; one at a time), filter sheet (route; state = Needs route/Failed/Done, one state per request), SSE updates
(refetch on `memo.updated`), native `.swipeActions` (full swipe = done / archive, the second revealed button = favorite / delete, delete only for
settled memos), 5 s undo toast (one at a time). New `IrisTests` unit target (model/filter tests vs FakeAPIClient); `HistoryFilters`/`HistoryToast`
also compile into IrisMac. Follow-ups: two stale-completion tests cannot prove ordering (FakeAPIClient cannot delay a response: give it a gate);
no step-progress dashes on in-flight rows; the dark-mode search field shows no placeholder in the screenshot; "Further right/left" is a second
button, not a second full-swipe threshold (owner may want the latter).
**For the next wave:** Wave 14 per its sketch. Lead lessons: `rd merge` needs a worktree holding the branch (`git worktree add` for a lead-made
fix branch). A branch whose commits fight each other on rebase is faster squashed to its net diff. The `agw` CLI was renamed `agw-legacy`
mid-wave (same commands). Account `me2` reached ~99 % of its window during I1.

## Wave 14 — Pele + speech-ready answers (server) ∥ memo detail, Stats, Settings, typed composer (iOS)            <!-- status: done -->
Backlog 4b's rendering half and the rest of backlog 6. Design is binding: `feedback-round-1.md` + `feedback-round-2.md` (round 2
wins). Two tracks: **S** (`server/**`, `contracts/**`, `scripts/**` + each contract's `IrisCore` follow-up) and **I** (`apple/**`).
Lessons from Waves 12–13 apply: S PRs land one at a time with `make e2e` before the train; additive conflicts are resolved in the
lead; one `xcodebuild` worker at a time, so I2 and I3 run one after the other; a fix branch for `rd merge` needs its own worktree.
- [x] **S1. Mermaid via Pele** (`obsidianmd/pele`): `/research` the rasterizer first (Bun-compatible, maintained, no headless
      browser if avoidable) and record the choice and why in TDD §3. When a reply is stored, every Mermaid block renders to an SVG
      for light and dark (basalt-ui colours through Pele's CSS variables) plus rasterized PNGs; the assets are stored with the memo,
      served by an authenticated media route, removed with the memo's purge, and the reply wire references them per block. A block
      Pele cannot render stays a code block (logged, never a step failure). Contract + fixtures + `IrisCore`.
- [x] **S2. Speech-ready answers:** next to the rendered reply the server produces the speech variant (code, diagrams, tables and
      URLs stripped or summarized; past a length threshold the `triage` `spoken` summary plus "details on screen"); `/speech` speaks
      it, so [Play] and spoken replies never read markdown. A retry that changes the reply re-derives it (the existing text-keyed cache).
- [x] **S3. Wave 13 debt:** a hang-guard timeout (decide/triage, 30 min) is not retried as transient (a hung step fails after one
      window, not ~90 min); the per-thread queue gets a bounded wait (a stuck turn fails the waiting one with a clear error).
- [x] **I2. Memo detail** per round 2: transcript; round 1's player (play/pause left, scrubbable timeline, one 10 s-back icon right,
      no speed); the full-width step waterfall with one `duration · cost` chip per step, faster/slower only where the stats baseline
      has enough samples (the client's threshold), attempts per step and [Retry from step]; icon-only bottom actions (play, reply,
      retry); the reply as markdown (full conversation rendering incl. Pele images is Wave 15); steps advancing animated, subtle. Also
      the step-progress dashes on in-flight History rows. Snapshot tests light + dark, screenshots against the round-2 renders.
- [x] **I3. Stats, Settings, typed composer:** the Stats tab (volume per route per day/week, trends) from `GET /v1/stats`; Settings
      with an obvious Diagnostics row (copy the memo id, animated "Copied"; no hide-cost toggle) and an outbox section ready for
      capture; the typed-memo composer (modes incl. Chat, `POST /v1/memos/text`). Fixes: the dark-mode search placeholder;
      `FakeAPIClient` gets a gate so the stale-completion tests prove ordering.
- [x] Deploy and prove: `make verify` + `make smoke`; a production chat memo whose answer contains a Mermaid block and code shows
      the assets and a clean speech variant; `apple.yml` green; TDD and AGENTS.md amended. Delete `~/.iris/data/iris.db.pre-w13-flags.bak`
      once this deploy runs cleanly.
**Left behind:** Five PRs, each landed by the train after a green full `make check` (S PRs also `make e2e` in the worker): #21 speech, #22 debt,
#23 Pele, #24 memo detail, #25 Stats/Settings/composer (+ FakeAPIClient gate). `agw review` (job API) on all five; its adversary angle failed on
#21–#24 (IU/Requesty 402 "Insufficient Balance"), so the lead read those diffs itself. Every blocking finding was fixed before merge (#21: fences
indented under list items were spoken raw, a one-line ```` ```foo``` ```` span swallowed the rest of the reply). Non-blocking findings fixed too:
#22 a leaked 30-min timer per served waiter, a duplicated busy message; #23 ENOENT-only error mapping, orphan files after a failed row write, log
names, CSP on SVGs. #25 review clean (all angles). The lead added one lint-wrap commit on #23 (`b6ae54a`). `check` and `apple.yml` green through `d57a15b`.
**Deploy:** server deployed `d3d8211` (I2/I3 are apple-only); `make verify` healthy, user_version 11. **`make smoke` fails at `summarize` and will
keep failing:** agw `triage` runs on an IU model through Requesty, which answers 402: memo `d7cd679f-…`, step error `agw triage failed: IU request
failed (503): [Requesty-Global StatusCode: PaymentRequired] … Insufficient Balance`. Owner decision 2026-10-28: Requesty is not topped up, so a
Hermes memo ends `failed(summarize)` after a successful `act` until the triage model moves off Requesty (an agent-gateway routing change, not Iris).
The rest was proven in production with a typed chat probe through `act` (smoke token, `POST /v1/memos/text`, mode chat): the reply carried a
mermaid and a ts block; `replyBlocks[0]` listed svg+png × light+dark; all four assets 200 (SVG with `content-security-policy`, PNG 512×128 at 2x,
no `var(` left), 401 without auth, 404 for an unknown asset; the dark PNG renders in basalt colours; the speech variant was "ein Diagramm / ein
Codeblock / <sentence>" (no markdown) and `/speech` returned 47 KB mp3; DELETE then purge after the window removed the asset dir, the
`reply_assets` rows and the memo. `~/.iris/data/iris.db.pre-w13-flags.bak` deleted. TDD §4 Screens amended to what is built.
**S1 (#23):** `pele` 1.10.0 (MIT, sync, no DOM, under Bun) + `@resvg/resvg-js` 2.6.2 (native, no browser); `/research` was down (503), so the
choice rests on npm/GitHub/type declarations and Bun probes (TDD §3 says so). Theme variables are resolved into the SVG (resvg ignores `var()`);
PNG 2x, ≤ 4096 px; the macOS Helvetica files are named so resvg skips the font scan. Migration 11 `reply_assets`; `GET /v1/memos/:id/assets/:assetId`;
renders serialized per memo. Follow-up: assets are written outside the `completeStep` transaction (a step that loses its CAS can leave assets for an
uncommitted reply until the next render or the purge; documented); no backfill for older replies; `make e2e` uses the fake renderer.
**S2 (#21):** `memo/speech-text.ts`, derived per `/speech` call, never stored (no wire change, no migration); language from the reply (tie → German);
600 cleaned characters, past that the triage `spoken` summary (clipped) + "Details auf dem Bildschirm." / "Details on screen."; a short reply is now
spoken whole instead of the summary.
**S3 (#22):** `hangGuardFailure` for the agw 30-min guard and the Hermes idle watchdogs (one window, no retry); `createKeyedQueue({maxWaitMs, sleep})`
with a cancellable wait, 30 min for the thread queue, `KeyedQueueTimeout` "thread <id> is busy …". Follow-ups: the audio-gateway STT/speech timeouts
still count as transient; a waiter parked on a thread queue holds a `driveAll` slot; herdr's per-pane queue stays unbounded (5 s call timeouts).
A flaky `audio-gateway.test.ts` temp-dir count was seen once while three workers ran tests in parallel.
**I2 (#24):** detail per round 2 (player via `MemoMediaSource`, waterfall, baseline threshold, attempts, retry from step, icon actions, markdown
reply, SSE), step dashes on History rows. Follow-ups: `AuthenticatedMediaSource` uses the undocumented `AVURLAssetHTTPHeaderFieldsKey` and is not
wired (`CompositionRoot` is fake-only; there is no production composition yet); the player polls every 250 ms instead of a time observer; no waveform.
**I3 (#25):** Stats (day/week, tiles, trends; no Chat series, chats route to Hermes; "Busiest" instead of the Audio tile), Settings (Diagnostics,
connection, outbox port), composer (5 modes, thread continuation from detail), dark search placeholder fixed, `FakeAPIClient.hold(_:)` with the
stale-completion tests rewritten, `PipelineSteps.applicable(to:)`, `MemoPlayback`. Follow-ups: Cancel stays enabled during a send; `StatsModel`/
`SettingsModel.load()` lack History's generation guard; the cost tile prints four decimals on dollar totals (`$1,6200`).
**For the next wave:** the fleet is **paused** after this wave (owner, 2026-10-28); Wave 15 stays pending. On resume: move triage off Requesty
(or top it up) before trusting `make smoke`; wire a production composition (real `URLSessionAPIClient` + `AuthenticatedMediaSource`).

## Wave 15 — R3 conversations (iOS) + simulator parts of R1 capture ∥ server debt            <!-- status: active -->
Backlog 7, the simulator-testable part of backlog 2, Wave 14's "for the next wave" (production composition) and the server carry-forward
debt. Design is binding: `feedback-round-1.md` + `feedback-round-2.md` (round 2 wins); TDD §4 Screens names Textual for the thread.
Two tracks: **S** (`server/**`, `contracts/**`, `scripts/**` + any contract's `IrisCore` follow-up) and **I** (`apple/**`). S and I run in
parallel; inside I one `xcodebuild` worker at a time, in the order I1 → I2 → I3 → I4 (each builds on the last). S PRs land one at a time
with `make e2e` before the train. Workers touching `IrisCapture`, intents or the Live Activity load the `apple-capture-notes` skill first.
**Decision (mother, 2026-10-28): no token stream.** Hermes is configured for final-answer only and `act` already collects the final text;
"smooth streaming" is a client reveal of the final answer when the memo's SSE update lands, not a new server stream. TDD records it.
- [x] **I1. Production composition + iOS debt:** a production `CompositionRoot` (real `URLSessionAPIClient`, server URL and device token
      from Settings' connection, token in the Keychain) next to the fake one, selected by launch argument (`-IrisFakeCapture` / fake API
      keep every existing UI test on fakes). Replace `AuthenticatedMediaSource`'s undocumented `AVURLAssetHTTPHeaderFieldsKey` with a
      documented path (an `AVAssetResourceLoaderDelegate` or an authenticated download to a cache file; pick one, record why in TDD).
      Debt: `StatsModel`/`SettingsModel.load()` get History's generation guard; composer Cancel is disabled during a send; the cost tile
      formats dollars to two decimals in the user's locale (`$1.62` / `1,62 $`, never `$1,6200`); the player uses a periodic time
      observer instead of 250 ms polling. Tests for each fix.
- [x] **I2. Thread view (backlog 7):** a History row of a Chat or multi-turn Hermes memo opens the thread view
      (`GET /v1/threads/:id`); the Chats chip already lists them. Messages rendered with Textual, scope = what Hermes emits: text, lists,
      links, syntax-highlighted code, tables (cards on narrow widths), Mermaid as the server's `replyBlocks` PNGs for the current
      appearance, tap opens a zoomable full view (pinch, double-tap, share). A turn in flight shows a pending assistant bubble with the
      step dashes; when SSE delivers the reply it reveals smoothly (subtle, no fake typing of thinking). Reply into the thread by text
      (the composer bound to `threadId`) and by voice (a capture request bound to `threadId` through the capture port; the fake capture
      until I3). Snapshot tests light + dark on fixtures with every block type.
- [ ] **I3. Capture core (backlog 2, simulator part):** `IrisCapture` for real behind its ports (audio session, routes, segment
      recorder, upload) wired onto `IrisCore`; the **outbox queues whole memos and chat messages** (typed, voice, thread replies), retries
      with backoff, survives relaunch, and Settings shows it as a queue (I3 of Wave 14 left the port). `StartMemoIntent` + Control
      compile and run on the simulator; Live Activity client phases recording/paused/uploading (Wave 7 carry-forward).
      `-IrisFakeCapture` UI tests for record → upload → processing → done, and for offline → queued → sent.
- [ ] **I4. Capture UI (backlog 2, simulator part):** start recording from any screen; while browsing the take continues as a
      **compact top banner** (tap returns to the full take); leaving the app moves it to the Live Activity; Dynamic Island with icon controls
      (stop, mic swap, pause), animated step progress, several queued memos; the done card's checkmark aligned. Snapshot tests on the
      pinned simulator (Dynamic Island model). Device exit checks (lock screen, background take, Bluetooth) stay for pairing.
- [ ] **I5. iPhone reply flow review render:** the reply flow (thread view → reply by voice/text → pending → answer) as simulator
      screenshots light + dark, uploaded as private links via `/img`, listed in `docs/design/README.md` under open questions for the
      owner's async review. Built as designed in I2/I4; the review never blocks the wave.
- [x] **S1. Server debt:** audio-gateway STT/speech timeouts fail after one window like the hang guard (not retried as transient);
      a waiter parked on a thread queue no longer holds a `driveAll` slot; herdr's per-pane queue gets a bound (fail clearly past it);
      Pele assets are written inside or reconciled with the `completeStep` transaction (no assets for an uncommitted reply survive);
      a backfill renders assets for older replies (idempotent, a `make` target or a boot-time sweep, bounded). TDD amended.
- [x] **S2. Multi-word spoken tab names:** the decision row records the matched word count so a spoken prefix can name a
      multi-word herdr tab; tests with one-, two- and three-word labels and a near-miss. Contract only if the wire changes.
- [ ] Deploy and prove: `make verify` (+ `make smoke`, which still fails at `summarize` until triage leaves Requesty: note it, do not
      block); a production thread probe (typed chat, then a continuation) reads back through `GET /v1/threads/:id`; `apple.yml` green;
      TDD and AGENTS.md amended.
**Left behind (in progress, lead):** merged by the train so far: #26 S1a, #27 S1b, #28 S2 (server: `make check-server check-contracts guard`
+ `make e2e` per merge; the full `make check` builds Xcode and collided with a running I worker), #29 I1, #30 I2 (full `make check`).
`agw review` (CLI) on every PR, blocking findings fixed before merge (#28: a failed herd read was re-read, so a label-less prefix could
resolve to the wrong tab). Non-blocking fixes taken: #26 per-drive slot tokens, body-read timeouts as hang guards; #27 stale pending
entries cleared, stoppable boot backfill; #29 https-only connection form (http for loopback); #30 plural turn count, toast timer.
The lead resolved one AGENTS.md conflict on #27. `apple.yml` + `check` green on master through #30.
**Deploy:** server `3028113` deployed, `make verify` healthy; the boot backfill ran (`reply.backfill` examined 0). Production thread probe
with the smoke token: typed chat `256ac9d0-…` then a continuation `f859f57c-…`, both `notified`; `GET /v1/threads/:id` returned kind
`chat`, 2 memos, 4 messages in order. `make smoke` not rerun (fails at `summarize` until Wave 16).
**Follow-ups so far:** I1: the step chip and the Stats per-memo caption still print a fixed `$` with four decimals; History is blank (no
prompt) without a connection; the Keychain round trip is untested (the unsigned simulator build has no Keychain, -34018); the media
cache is never evicted for deleted memos; one `URLSession` per player. I2: **`MemoDetailView` keeps the old `.task(id: failure)` toast,
so a stale timer can hide a newer toast (fixed in the thread view only)**; reply-image loading is unbounded; `MediaDownloader` is not
single-flight; the fake voice capture clears before stop; Textual pinned `exact: 0.5.0`. S1a: a second concurrent `driveAll` for a parked
memo holds its slot until the memo finishes (no production path). S1b: asset rows are visible briefly before the reply commits; a lost
compare-and-set drops the earlier reply's assets until the next boot backfill; a memo whose every block fails re-renders each boot (≤ 50).

## Wave 16 — summarize optional (server) + next backlog            <!-- status: pending -->
Sketch; written in full by the mother when Wave 15 closes. Fixed item, owner-confirmed 2026-10-28:
- [ ] **Summarize is optional.** A failed `summarize` (agw `triage` error, e.g. the Requesty 402, after its retries) no longer fails the
      memo: a Hermes memo whose `act` succeeded ends `done` without a summary. The step stays visible with its error and attempts (the
      waterfall shows it as failed-but-optional, [Retry from step] still works and fills the summary in later); the History headline falls
      back to the transcript; the speech variant past the length threshold falls back to the clipped cleaned reply instead of the `spoken`
      summary. Existing `failed(summarize)` memos with a reply move to `done` (one migration or repair, idempotent). Contract + fixtures +
      `IrisCore` if the step or memo wire changes; TDD and AGENTS.md amended. Proof: `make smoke` green with triage still on Requesty.

## Fleet backlog (for the long-running fleet: mother → lead → workers)

Not waves of this chain. The fleet's mother turns these into active waves, one at a time,
refining scope from TDD/PRD. Releases are named in PRD §Release plan. **Design is binding:**
`docs/design/feedback-round-1.md` and `docs/design/feedback-round-2.md` (round 2 wins where they conflict). No further
design round; a genuinely new surface gets a render sent to the owner for async review, never a blocking round.
**Ordering while the owner is away (no paired iPhone until he is home):** items that need no phone first (4b, 6, 7,
then the simulator-testable parts of 2, 5, 8). Items 1, 3 and the device exit checks of 2 and 5 wait for pairing.

0. ~~Design round 2~~ — done (Wave 10); the owner's verdict is `feedback-round-2.md`.
1. **Spikes S1–S3** on the iPhone (`docs/spikes/`). They need the owner's hands, pairing and
   (for S3) enrollment. Findings amend TDD.
2. **R1 capture:** `IrisCapture` for real (session, routes, segment recorder, outbox),
   `StartMemoIntent` + Control + Live Activity (client phases recording/paused/uploading, Wave 7
   carry-forward), package wiring onto `IrisCore`. Round 2: **start recording from any screen**, the take continues as a
   **compact top banner** while browsing and moves to the Live Activity on leaving the app; the **outbox queues whole
   memos and chat messages** (not only segments) and Settings shows it as a queue; Dynamic Island icon controls (stop,
   mic swap, pause) with **animated step progress** and several queued memos; the done card's checkmark aligned.
   `-IrisFakeCapture` UI tests. (`POST /v1/telemetry` moved to Wave 12.)
3. **R1 results:** APNs registration, notification categories + content extension, the result
   long-poll backstop, Live Activity remote updates. TestFlight pipeline (`make testflight`) once
   enrolled.
4. ~~R2 routing (server)~~ — done (Waves 10–11).
4b. **R3 server completion** (no phone): memo flags for the swipe actions — **done**, **favorite**, **archived**, and
   **delete** as a soft delete with an undo window, then purge — with list filters and quick-filter support (Favorites,
   Chats, Needs route; archived/deleted hidden by default); **automatic retries** of transient step failures (two, with
   exponential backoff; TDD §3 says they are not built, round 2 assumes they are) with the attempt count on the wire per
   step; whatever Wave 12 left behind (threads from Iris's own memos, per-step-and-route baselines with n); a reply
   stream for chat/thread views if the thread view needs live tokens (final answer only, smooth). **Mermaid via Pele**
   (`obsidianmd/pele`, MIT, sync TS): when a reply is stored, render each Mermaid block to an SVG themed for light and dark
   plus rasterized PNGs for the native views, served as reply assets; confirm the rasterizer with `/research` (Bun-compatible,
   maintained) and record it in TDD §3. **Speech-ready variant** of every answer, produced next to the rendered reply: code,
   diagrams, tables and URLs stripped or summarized; a long answer speaks the `triage` `spoken` summary plus "details on
   screen"; `/speech` (and so [Play] and spoken replies) speaks this variant. Swift `IrisCore` follow-up.
5. **R2 routing (iOS):** the mode picker incl. Chat, needs-route actions, [Play] via
   `PlayReplyIntent`, per-route mic rules, spoken-replies setting. (The cost-on-Lock-Screen toggle is dropped by round 2.)
6. **R3 history (iOS):** tabs **History · Stats · Settings** (no Threads tab, owner-confirmed; the freed slot stays empty,
   reserved for PRD §Later surfaces, which are not built now). History is the one list of everything:
   rows like round 1, **swipe actions** (right: done, further right: favorite; left: archive, further left: delete with
   undo), **quick-filter chips** (Favorites, Chats, Needs route, …) next to search and the bottom-sheet filter, SSE live
   updates. Memo detail per round 2: round 1's player (play/pause, scrub, one 10 s-back icon, no speed), the full-width
   step waterfall with one `duration · cost` chip per step, faster/slower only where a baseline is meaningful, attempts
   per step + [Retry from step], icon-only bottom actions. Stats view. Typed-memo composer. Settings with an obvious
   Diagnostics row (copy the memo id, animated "Copied"). Motion explains state (steps advancing, copy, queue), subtle;
   colour earns its place. Snapshot tests on the pinned simulator.
7. **R3 conversations (iOS):** a Chat or multi-turn Hermes memo is a History row that opens the **thread view**; the
   Chats quick filter lists them. **Scope = what Hermes actually streams, nothing more:** text, lists, links,
   syntax-highlighted code, tables (cards on narrow widths) and Mermaid as the server-rendered images from 4b (tap opens a
   zoomable full view); smooth final-answer streaming. Reply by voice or text into a thread; the
   **iPhone reply flow** (new surface: render it and send it for async owner review while building).
8. **R4 Mac:** the menu-bar app (its **history rows match mobile History**), hotkey (configurable, default distinct from
   the owner's dictation key), panel, capture on the Mac, SSE notifications with Reply.
9. **R5 polish:** on-device live preview (`SpeechTranscriber`, German checked at runtime),
   widgets, spoken-replies mode, `.xcstrings` catalogs, alerts + health probe (TDD §8 Later).
10. **Housekeeping after R3's screens ship:** delete the round-1/2 mockup image objects (via `/img`, incl. the stray
    `r2-detail-light` test upload), `iumac:/tmp/iris-mockups.html` + `/tmp/iris-mockups/` and `docs/design/renders/`.
