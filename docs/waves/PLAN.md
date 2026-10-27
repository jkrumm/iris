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

## Fleet backlog (for the long-running fleet: mother → lead → workers)

Not waves of this chain. The fleet's mother turns these into active waves, one at a time,
refining scope from TDD/PRD. Releases are named in PRD §Release plan. The owner reviewed the
mockups on 2026-10-27: `docs/design/feedback-round-1.md` is binding for every UI item.
**Ordering while the owner is away (no paired iPhone until he is home):** start with items that
need no phone (0, 4, 6, 7). Items 1–3 and 5 need the device for their exit checks and wait for
pairing. Build their simulator-testable parts earlier if the queue runs dry.

0. **Design round 2:** apply `feedback-round-1.md` to the mockups:
   - the memo detail waterfall (collapsed), the player with 10 s back, less shadow, no trace id;
   - the Dynamic Island mic-swap icon, compact notification actions, Mac Reply;
   - new surfaces: Chat mode, typed memo, History filters, Stats, the Threads view.
   Render and upload like Wave 9. The owner reviews; until he answers, build the unchanged
   surfaces.
1. **Spikes S1–S3** on the iPhone (`docs/spikes/`). They need the owner's hands, pairing and
   (for S3) enrollment. Findings amend TDD.
2. **R1 capture:** `IrisCapture` for real (session, routes, segment recorder, outbox),
   `StartMemoIntent` + Control + Live Activity (client phases recording/paused/uploading, Wave 7
   carry-forward), the Record screen, `-IrisFakeCapture` UI tests, package wiring onto `IrisCore`,
   `POST /v1/telemetry` on the server.
3. **R1 results:** APNs registration, notification categories + content extension, the result
   long-poll backstop, Live Activity remote updates. TestFlight pipeline (`make testflight`) once
   enrolled.
4. **R2 routing (server):** prefix parser, `decide`, journal + herdr destinations, `needs_route`,
   corrections, templated summaries, **Chat mode** (Hermes session with a no-side-effects system
   message; confirm this reading with the owner when the item starts), typed memos (skip STT),
   agw `caller` field (a small change in agent-gateway). Plus Wave 5's carry-forward (composition
   dedupe, `MEMO_NEEDS_ROUTE`, `+faststart`).
5. **R2 routing (iOS):** the mode picker incl. Chat, needs-route actions, [Play] via
   `PlayReplyIntent`, per-route mic rules, spoken-replies setting, cost-on-Lock-Screen setting.
6. **R3 history:** History + search + filters, memo detail per round 2, SSE live updates, Stats
   (server aggregates + view), the typed-memo composer.
7. **R3 threads:** the Threads view (Textual), reply by voice or text into a thread, Chat threads.
8. **R4 Mac:** the menu-bar app, hotkey (configurable, default distinct from the owner's
   dictation key), panel, capture on the Mac, SSE notifications with Reply.
9. **R5 polish:** on-device live preview (`SpeechTranscriber`, German checked at runtime),
   widgets, spoken-replies mode, `.xcstrings` catalogs, alerts + health probe (TDD §8 Later).
10. **Housekeeping after R3's screens ship:** delete the round-1/2 mockup image objects (via `/img`),
    `iumac:/tmp/iris-mockups.html` and `docs/design/renders/`.
