# Ledger of the root AGENTS.md split

The root `AGENTS.md` was 127,848 bytes (473 lines). Each block of it below has its line range in that version (`git show 74cc7e1:AGENTS.md`), its bytes and where it lives now. `verbatim` means the text moved to `docs/` unchanged; a nested `AGENTS.md` carries the rule form. This page is a record, not an instruction.

| Lines | Bytes | Block | Now in |
|-|-|-|-|
| 1-1 | 30 | # iris — Agent Instructions | root `AGENTS.md` (intro) |
| 3-6 | 649 | Voice channel into the agent platform. A memo recorded on a phone is u | root `AGENTS.md` (intro) |
| 8-8 | 10 | ## Layout | deleted: the directory tree and `make help` say it; the web bundle path and generated files are in root Requirements |
| 10-22 | 1568 | \| Path \| Holds \| | deleted: the directory tree and `make help` say it; the web bundle path and generated files are in root Requirements |
| 24-24 | 20 | ## Rules and skills | deleted: skill descriptions load every turn and say when to use each; the merged rule rows are replaced by root "Where to look" |
| 26-30 | 416 | \| Rule (lazy, by path) \| Covers \| | deleted: skill descriptions load every turn and say when to use each; the merged rule rows are replaced by root "Where to look" |
| 32-40 | 703 | \| Skill \| Use when \| | deleted: skill descriptions load every turn and say when to use each; the merged rule rows are replaced by root "Where to look" |
| 42-42 | 24 | ## Tooling setup (mini) | root Requirements (no MCP, dev servers, simulators) and `apple/AGENTS.md` (`proof-apple`, `scripts/mbm`); Xcode, xcodes, XcodeGen and the pinned simulator deleted: Makefile `SIM_NAME`/`SIM_OS`, skill `apple-dev` |
| 44-49 | 1071 | Xcode 27.1 via xcodes (~/.local/bin/xcodes, installed by dotfiles/scri | root Requirements (no MCP, dev servers, simulators) and `apple/AGENTS.md` (`proof-apple`, `scripts/mbm`); Xcode, xcodes, XcodeGen and the pinned simulator deleted: Makefile `SIM_NAME`/`SIM_OS`, skill `apple-dev` |
| 51-51 | 22 | ## Server (server/) | heading dropped |
| 53-53 | 135 | - server/src/app.ts — createApp({deviceTokens, memos, stats?, degraded | `docs/server-design.md` (Module map, verbatim); rules in `server/AGENTS.md` |
| 54-55 | 183 | - server/src/index.ts — entry point: SQLite, audio-fs, runner, service | `docs/server-design.md` (Module map, verbatim); rules in `server/AGENTS.md` |
| 56-59 | 1005 | - server/src/memo/ — domain: memo.ts (states, steps, transitions, runs | `docs/server-design.md` (Module map, verbatim); rules in `server/AGENTS.md` |
| 60-61 | 344 | - server/src/pipeline/steps.ts — createStepHandlers: the four step han | `docs/server-design.md` (Module map, verbatim); rules in `server/AGENTS.md` |
| 62-65 | 1440 | - server/src/adapters/ — sqlite.ts (+ sqlite-migrations.ts, PRAGMA use | `docs/server-design.md` (Module map, verbatim); rules in `server/AGENTS.md` |
| 66-69 | 643 | - server/src/ports/ — audio.ts (AudioStore, AudioCombiner, Recording), | `docs/server-design.md` (Module map, verbatim); rules in `server/AGENTS.md` |
| 70-72 | 408 | - server/src/notify/ — payloads.ts (pure alert / Live Activity builder | `docs/server-design.md` (Module map, verbatim); rules in `server/AGENTS.md` |
| 73-76 | 534 | - server/src/http/ — auth.ts (device-token guard), memos.ts, devices.t | `docs/server-design.md` (Module map, verbatim); rules in `server/AGENTS.md` |
| 77-80 | 485 | - server/src/telemetry/ — otel.ts, otel-format.ts, log.ts, copied from | `docs/server-design.md` (Module map, verbatim); rules in `server/AGENTS.md` |
| 81-81 | 66 | - server/src/env.ts — the only place process.env is parsed. | `docs/server-design.md` (Module map, verbatim); rules in `server/AGENTS.md` |
| 82-84 | 330 | - server/src/contracts/ — registry.ts (contract name → TypeBox schema) | `docs/server-design.md` (Module map, verbatim); rules in `server/AGENTS.md` |
| 85-87 | 308 | - contracts/ — the wire contract Swift decodes: schema/<name>.json (ge | `docs/server-design.md` (Module map, verbatim); rules in `server/AGENTS.md` |
| 88-90 | 389 | - server/src/compose.ts — compose({env, db, devices, clock, dataDir}): | `docs/server-design.md` (Module map, verbatim); rules in `server/AGENTS.md` |
| 91-92 | 251 | - scripts/ — send-memo.ts (driver), e2e.ts (make e2e), smoke.sh, launc | `docs/server-design.md` (Module map, verbatim); rules in `server/AGENTS.md` |
| 95-95 | 25 | ## Web renderer (web/) | `web/AGENTS.md` (intro) + `docs/web-renderer.md` |
| 97-98 | 339 | One static page (Vite 8, React 19, strict TypeScript, bun) that the iO | `web/AGENTS.md` (intro) + `docs/web-renderer.md` |
| 100-100 | 780 | - **Payload** (src/payload.ts, hand-written guard parsePayload): artif | `web/AGENTS.md` (rules) + `docs/web-renderer.md` (verbatim) |
| 101-101 | 466 | - **Show specs** (src/show/): table, chart (bar, line, area, pie), sta | `web/AGENTS.md` (rules) + `docs/web-renderer.md` (verbatim) |
| 102-102 | 513 | - **Markdown docs** (src/doc/Markdown.tsx): react-markdown, remark-gfm | `web/AGENTS.md` (rules) + `docs/web-renderer.md` (verbatim) |
| 103-103 | 1292 | - **HTML docs** (src/doc/HtmlDoc.tsx): <iframe sandbox="" srcdoc scrol | `web/AGENTS.md` (rules) + `docs/web-renderer.md` (verbatim) |
| 104-104 | 424 | - **Height and bridge:** the host's injected script (isolated world) r | `web/AGENTS.md` (rules) + `docs/web-renderer.md` (verbatim) |
| 105-105 | 1215 | - **CSP and build rules.** index.html carries a meta CSP (default-src  | `web/AGENTS.md` (rules) + `docs/web-renderer.md` (verbatim) |
| 106-106 | 1122 | - **Change it:** edit web/, run make web-build (builds in a temp dir,  | `web/AGENTS.md` (rules) + `docs/web-renderer.md` (verbatim) |
| 107-107 | 985 | - **Libraries (measured 2026-11-10, gzip -9 of the built output):** to | `web/AGENTS.md` (rules) + `docs/web-renderer.md` (verbatim) |
| 109-109 | 12 | ## HTTP API | `docs/http-api.md` (verbatim) |
| 111-111 | 86 | All under /v1, Authorization: Bearer <token>. Errors: {error: <code>,  | `docs/http-api.md` (verbatim) |
| 113-135 | 6364 | \| Route \| Result \| | `docs/http-api.md` (verbatim) |
| 137-140 | 386 | Codes: not_found 404, conflict / bad_state / destination_unavailable 4 | `docs/http-api.md` (verbatim) |
| 143-143 | 30 | ## Device (the paired iPhone) | `docs/device.md` (verbatim); `scripts/AGENTS.md` (Device scripts) |
| 145-148 | 611 | make device builds, signs, installs, launches Iris and screenshots the | `docs/device.md` (verbatim); `scripts/AGENTS.md` (Device scripts) |
| 149-152 | 551 | - **Signing is one switch, paid by default.** DEVICE_SIGNING=paid sign | `docs/device.md` (verbatim); rule form in `scripts/AGENTS.md` (Device scripts) |
| 153-159 | 1039 | - **The App Group is on for paid builds** (verified 2026-11-05, iPhone | `docs/device.md` (verbatim); rule form in `scripts/AGENTS.md` (Device scripts) |
| 160-162 | 476 | - **The key file's life:** 1Password flattened the .p8 newlines into s | `docs/device.md` (verbatim); rule form in `scripts/AGENTS.md` (Device scripts) |
| 163-167 | 698 | - **Personal Team is the fallback** (DEVICE_SIGNING=personal): the fre | `docs/device.md` (verbatim); rule form in `scripts/AGENTS.md` (Device scripts) |
| 168-170 | 1009 | - **APNs on the phone:** PushRegistrar (apple/Iris, PushAppDelegate fo | `docs/device.md` (verbatim) |
| 171-173 | 399 | - **First install:** the first -allowProvisioningUpdates build registe | `docs/device.md` (verbatim); `scripts/AGENTS.md` (Device scripts) |
| 174-175 | 212 | - **Screenshot:** xcrun devicectl device capture screenshot (Xcode 27) | `docs/device.md` (verbatim); `scripts/AGENTS.md` (Device scripts) |
| 176-178 | 458 | - **Connecting the app** has no launch-argument route (no production b | `docs/device.md` (verbatim); `scripts/AGENTS.md` (Device scripts) |
| 179-185 | 1004 | - **Device observability (TDD §8):** every capture, route, interruptio | `docs/device.md` (verbatim); rule in `apple/AGENTS.md` (device events) |
| 187-187 | 12 | ## Validate | `docs/validate.md` (verbatim); root Validate; detail also in `make help` |
| 189-205 | 4232 | \| Target \| Runs \| Where \| | `docs/validate.md` (verbatim); root Validate; detail also in `make help` |
| 207-207 | 1637 | **apple.yml** runs three jobs that start together on hosted xcode-27 r | `docs/validate.md` (verbatim); root Validate; `apple/AGENTS.md` (uitest map) |
| 209-209 | 1764 | **Machine budget (reset row 7b, mechanical):** locally **at most one t | `docs/validate.md` (verbatim); root Time and cost; `scripts/AGENTS.md` (Apple wrappers) |
| 211-211 | 1738 | **Simulator memory (Issue 677):** a stock iOS 27.0 iPhone 17 boots ~20 | `docs/validate.md` (verbatim); root Time and cost; `scripts/AGENTS.md` (Apple wrappers) |
| 213-214 | 290 | make format applies oxfmt. make generate builds apple/Iris.xcodeproj;  | deleted: `make help` (format, generate, theme, icons); root Requirements (generated files) |
| 216-218 | 350 | **Public repo:** no real hostnames, IPs, tailnet names, tokens or pers | root Requirements (public repo) |
| 220-220 | 32 | ### Server and pipeline details | heading dropped |
| 222-225 | 601 | make e2e (scripts/e2e.ts, CI after check, needs ffmpeg) boots server/s | `docs/server-design.md` (verbatim); `scripts/AGENTS.md` (Drivers) |
| 227-229 | 317 | **IRIS_FAKES=1** (boolean-ish, empty = off) builds every port from com | `server/AGENTS.md` (Structure and tests) |
| 231-233 | 301 | make check-contracts — the exported JSON Schemas equal contracts/schem | `contracts/AGENTS.md`, root Requirements, `make help` |
| 235-236 | 189 | Tests are colocated *.test.ts. Ports and adapters: dependencies are in | `server/AGENTS.md` (Structure and tests) |
| 238-243 | 664 | **Harness:** bun scripts/send-memo.ts <audio-file> is the end-to-end d | `scripts/AGENTS.md` (Drivers) |
| 245-245 | 10 | ## Deploy | root Deploy; `docs/release-and-ops.md` (verbatim) |
| 247-248 | 256 | project.yaml is the factory manifest (deploy.mode make, target mini, v | root Deploy; `docs/release-and-ops.md` (verbatim) |
| 250-253 | 337 | Push to master deploys. LaunchAgent com.jkrumm.iris (KeepAlive, ExitTi | root Deploy; `docs/release-and-ops.md` (verbatim) |
| 255-259 | 437 | - com.jkrumm.iris-deploy polls scripts/mini-deploy.sh every 120 s thro | root Deploy; `scripts/AGENTS.md` (Deploy and runtime); `docs/release-and-ops.md` (verbatim) |
| 260-260 | 106 | - First install or a changed launchd/ template: make mini-setup / make | root Deploy; `scripts/AGENTS.md` (Deploy and runtime); `docs/release-and-ops.md` (verbatim) |
| 261-261 | 2299 | - **TestFlight crash intake** (com.jkrumm.iris-testflight-crashes, hou | `scripts/AGENTS.md` (Deploy and runtime); `docs/release-and-ops.md` (verbatim) |
| 262-269 | 1132 | Secrets, env templates and token rotation | `scripts/AGENTS.md` (Deploy and runtime); `docs/release-and-ops.md` (verbatim) |
| 270-270 | 1211 | - **Versions** (scripts/version.ts, tests scripts/version.test.ts): bo | `scripts/AGENTS.md` (Deploy and runtime); `docs/release-and-ops.md` (verbatim) |
| 271-272 | 4014 | - **Release hooks** (Wave 22): after a deployed tick, and on every tic | `scripts/AGENTS.md` (Deploy and runtime); `docs/release-and-ops.md` (verbatim) |
| 273-273 | 292 | - HERMES_URL is composed in launch.sh from HERMES_HOST + HERMES_PORT.  | `docs/server-design.md` (verbatim) |
| 274-274 | 1060 | - agent-workflows host calls (POST /triage, synchronous) carry x-agw-p | `docs/server-design.md` (verbatim); `server/AGENTS.md` (Pipeline) |
| 276-276 | 20 | ## Verify & Monitor | root Verify & Monitor |
| 278-280 | 413 | - make verify — exit 0 iff GET /health answers status: ok (public; {st | root Verify & Monitor |
| 281-283 | 456 | - make smoke — a real German 96 s recording (fixtures/audio/de-90s.m4a | root Verify & Monitor |
| 284-285 | 189 | - make logs (bounded tail of ~/Library/Logs/iris{.log,.err} and iris-d | root Verify & Monitor |
| 286-287 | 157 | - Traces and logs: HyperDX, service.name=iris-server, trace id = memo  | root Verify & Monitor |
| 290-290 | 11 | ## Gotchas | root Gotchas (where a lesson goes) |
| 292-297 | 676 | - **Contracts:** change a route or schema → make contracts, update the | `contracts/AGENTS.md`; `server/AGENTS.md` (Wire contract) |
| 298-303 | 885 | - **Telemetry relay** (POST /v1/telemetry, TDD §8): the route reads an | `docs/server-replies-push.md` (verbatim); `server/AGENTS.md` (Wire contract, Telemetry) |
| 304-306 | 206 | - **Auth:** /v1/* requires Authorization: Bearer <token>; IRIS_DEVICE_ | `server/AGENTS.md` (Wire contract) |
| 307-308 | 142 | - **Elysia:** chain methods (types), and mount the guard with as: "sco | `server/AGENTS.md` (Wire contract) |
| 309-310 | 197 | - **Public repo:** no real hostnames, IPs, tailnet names, tokens or pe | root Requirements |
| 311-312 | 192 | - **Trust model:** every device token is trusted equally; memos, histo | root Requirements |
| 313-314 | 157 | - **Segments** are idempotent by sha256 (same bytes no-op, different b | `server/AGENTS.md` (Pipeline, idempotency) |
| 315-319 | 517 | - **Step results live on the memo row** (audio_seconds, transcript, de | `docs/server-design.md` (verbatim); rule in `server/AGENTS.md` (Pipeline) |
| 320-321 | 658 | - **Downstream env** (all optional, empty = unset): AUDIO_DOOR_URL (ht | `docs/server-design.md` (verbatim); rule in `server/AGENTS.md` (Pipeline) |
| 322-322 | 294 | - **Hermes client only** (Issue 403): Iris reaches the software factor | `docs/server-design.md` (verbatim); rule in `server/AGENTS.md` (Pipeline) |
| 323-330 | 2765 | - **Hermes decides** (TDD §3 "Hermes decides"; supersedes the routing, | `docs/server-design.md` (verbatim); rule in `server/AGENTS.md` (Pipeline) |
| 331-331 | 1159 | - **Summarize is optional** (OPTIONAL_STEPS in memo/memo.ts): summariz | `docs/server-design.md` (verbatim); rule in `server/AGENTS.md` (Pipeline) |
| 332-336 | 1524 | - **Threads** (TDD §3 act, data model): every Hermes session is a thre | `docs/server-design.md` (verbatim); rule in `server/AGENTS.md` (Pipeline) |
| 337-340 | 634 | - **Mode transcribe** (TDD §3 state machine): the pipeline is transcri | `docs/server-design.md` (verbatim); rule in `server/AGENTS.md` (Pipeline) |
| 341-345 | 649 | - **act is at-least-once:** a crash or restart mid-act replays the ste | `docs/server-design.md` (verbatim); rule in `server/AGENTS.md` (Pipeline) |
| 346-349 | 470 | - **Devices:** identity is the authenticated device name from the toke | `docs/server-design.md` (verbatim); rule in `server/AGENTS.md` (Pipeline) |
| 350-354 | 607 | - **Audio and speech are derived, disk-cached and single-flight:** the | `docs/server-design.md` (verbatim) |
| 355-359 | 1852 | - **Mermaid replies:** after act has the reply, memo/reply-assets.ts r | `docs/server-replies-push.md` (verbatim); rule in `server/AGENTS.md` (Pipeline) |
| 360-360 | 1082 | - **Reply artifacts:** memo/reply-artifacts.ts also reads two typed to | `docs/server-replies-push.md` (verbatim); rule in `server/AGENTS.md` (Pipeline) |
| 361-361 | 185 | - **Audio door timeouts are hang guards:** the STT call (30 min) throw | `docs/server-design.md` (verbatim); rule in `server/AGENTS.md` (Pipeline) |
| 362-365 | 632 | - **Audio door** (agent-workflows audio process, AUDIO_DOOR_URL = http | `docs/server-design.md` (verbatim); rule in `server/AGENTS.md` (Pipeline) |
| 366-367 | 190 | - **Speech request** to the door: POST /audio/speech {input, response_ | `docs/server-design.md` (verbatim); rule in `server/AGENTS.md` (Pipeline) |
| 368-370 | 319 | - **Schemas** in http/schemas.ts are the contract source: routes use t | `server/AGENTS.md` (Wire contract) |
| 371-384 | 2475 | - **APNs** (APNS_KEY_P8 PEM, literal \n or spaces for newlines allowed | `docs/server-replies-push.md` (verbatim); rule in `server/AGENTS.md` (Pipeline) |
| 385-390 | 755 | - **APNs transport:** node-apn builds the ES256 JWT with jsonwebtoken  | `docs/server-replies-push.md` (verbatim); rule in `server/AGENTS.md` (Pipeline) |
| 391-393 | 750 | - **Live Activity contract (Swift side):** payload aps is {timestamp,  | `docs/server-replies-push.md` (verbatim); `contracts/AGENTS.md` |
| 394-395 | 205 | - **Bookkeeping failures** (completeStep throws after a handler ran) l | `docs/server-design.md` (verbatim); `server/AGENTS.md` (Pipeline) |
| 396-396 | 113 | - A stored summary_json that fails the zod Summary schema reads as nul | `docs/server-design.md` (verbatim); `server/AGENTS.md` (Pipeline) |
| 397-397 | 80 | - **SSE** has no Last-Event-ID replay; clients refetch the list on rec | `server/AGENTS.md` (Wire contract) |
| 398-398 | 89 | - **Long polls and SSE** call server.timeout(request, 0) to escape Bun | `server/AGENTS.md` (Wire contract) |
| 399-399 | 54 | - **Secrets on the mini:** secrets-run, never op. | root Requirements |
| 400-400 | 97 | - server/package.json is imported by telemetry/otel.ts for service.ver | `server/AGENTS.md` (Structure and tests) |
| 401-402 | 249 | - **Apple build artifacts:** xcodebuild leaves apple/.dd.noindex and p | `apple/AGENTS.md` (Build and verify) |
| 403-403 | 1973 | - **Segment files** (Wave 18 I2): SegmentWriter writes each segment as | `docs/apple-capture.md` (verbatim); rules in `apple/Packages/IrisCapture/AGENTS.md` |
| 404-407 | 10284 | - **Capture and outbox** (Wave 15 I3, TDD §4): IrisCapture holds Captu | `docs/apple-capture.md` (verbatim); rules in `apple/Packages/IrisCapture/AGENTS.md` |
| 408-413 | 1966 | - **App composition:** -IrisFakeCapture (every UI test, make run-sim)  | `docs/apple-app.md` (verbatim); `apple/Packages/IrisUI/AGENTS.md` (media); `apple/AGENTS.md` (Keychain test) |
| 414-420 | 2493 | - **Thread view** (ThreadView / ThreadModel, TDD §4 "Thread view"): th | `docs/apple-app.md` (verbatim); rules in `apple/Packages/IrisUI/AGENTS.md` |
| 421-421 | 1069 | - **Reply artifacts on screen** (Issue 728, TDD §4 "Artifacts in the c | `docs/apple-app.md` (verbatim); rules in `apple/Packages/IrisUI/AGENTS.md` |
| 422-422 | 1887 | - **Artifact island** (IrisUI/Components/Artifact): ArtifactWebView(en | `docs/apple-app.md` (verbatim); rules in `apple/Packages/IrisUI/AGENTS.md` |
| 423-428 | 1658 | - **Capture and outbox failures:** the outbox stalls a transfer on a r | `docs/apple-capture.md` (verbatim); rules in `apple/Packages/IrisCapture/AGENTS.md` |
| 429-429 | 1270 | - **Optional summarize, money, offline History** (Wave 16 I2, TDD §4): | `docs/apple-app.md` (verbatim); `apple/Packages/IrisUI/AGENTS.md` (money) |
| 430-433 | 2005 | - **Take UI** (Wave 15 I4, TDD §4 Screens): one TakeController (start  | `docs/apple-app.md` (verbatim) |
| 434-434 | 946 | - **Live preview** (Wave 19 R1, TDD §4 "Live preview"): the take scree | `docs/apple-app.md` (verbatim) |
| 435-437 | 2561 | - **Two modes, the kind chip** (Wave 21 A1, TDD §4 "Two modes and the  | `docs/apple-app.md` (verbatim); `apple/Packages/IrisUI/AGENTS.md` (SpeechPlayer) |
| 438-438 | 419 | - **App icons:** apple/branding/logo.svg is the one source of the logo | `apple/AGENTS.md` (Rules for every Apple target) |
| 439-439 | 989 | - **Spacing:** no spacing literals in views; Theme.Spacing (IrisUI/The | `apple/Packages/IrisUI/AGENTS.md` (Theme); `docs/apple-app.md` (verbatim) |
| 440-440 | 1584 | - **Strings:** English is the source, every user-facing string has a d | `apple/AGENTS.md` (strings); `docs/apple-app.md` (verbatim); `make check-strings` enforces it |
| 441-441 | 641 | - **UI test waits:** a test never reads exists/frame of an element tha | `apple/AGENTS.md` (UI tests); `docs/apple-app.md` (verbatim) |
| 442-444 | 548 | - **UI tests and the clock:** the fake sample memos are relative to a  | `apple/AGENTS.md` (UI tests); `docs/apple-app.md` (verbatim) |
| 445-445 | 140 | - **Snapshots** only compare on the pinned simulator; a diff on a clea | `apple/AGENTS.md` (snapshots) |
| 446-446 | 1479 | - **Mac capture** (Wave 18 M2, TDD §5): the global key is KeyboardShor | `docs/mac-app.md` (verbatim); rules in `apple/IrisMac/AGENTS.md` |
| 447-447 | 367 | - **Mac server binding** (Wave 19 M1, TDD §5): MacCaptureStack gives C | `docs/mac-app.md` (verbatim); rules in `apple/IrisMac/AGENTS.md` |
| 448-448 | 829 | - **Mac popover** (docs/design/mockups/mac.html variant menu): MacMenu | `docs/mac-app.md` (verbatim); rules in `apple/IrisMac/AGENTS.md` |
| 449-456 | 8372 | - **Mac desktop app** (windows, not pages): three scenes declared in I | `docs/mac-app.md` (verbatim); rules in `apple/IrisMac/AGENTS.md` |
| 457-458 | 445 | - **Mac outbox panel** (Wave 19 M1, TDD §5): a strip under the panel h | `docs/mac-app.md` (verbatim); rules in `apple/IrisMac/AGENTS.md` |
| 459-461 | 579 | - **Mac telemetry** (Wave 19 M1, TDD §5): the Mac writes the same devi | `docs/mac-app.md` (verbatim); rules in `apple/IrisMac/AGENTS.md` |
| 462-466 | 934 | - **Mac notifications** (MemoNotifier, TDD §5) announce a **transition | `docs/mac-app.md` (verbatim); rules in `apple/IrisMac/AGENTS.md` |
| 467-467 | 4469 | - **Mac releases** (Wave 22 M2, TDD §5 "Updates"): IrisMac is **not sa | `docs/release-and-ops.md` (verbatim); `scripts/AGENTS.md` (Deploy and runtime); `apple/IrisMac/AGENTS.md` (sandbox) |
| 468-472 | 825 | - **scripts/mbm tap** needs --element-ref from the latest snapshot-ui  | `apple/AGENTS.md` (mbm, hardware-only); `docs/apple-capture.md` (verbatim) |
| 473-473 | 157 | - **TDD is the design, code is the truth for shipped behaviour:** §3 w | root intro (the code is the truth for shipped behaviour) |

## Sizes

Bytes loaded by instruction files. Before: the root file (127,848) plus the two path rules that load when work touches `apple/**` or `server/**`. After: the root file loads every turn; each nested file loads when work reaches its directory.

| File | Bytes | Loaded |
|-|-|-|
| `AGENTS.md` | 6868 | every turn |
| `server/AGENTS.md` | 6327 | on reach |
| `contracts/AGENTS.md` | 971 | on reach |
| `web/AGENTS.md` | 3157 | on reach |
| `apple/AGENTS.md` | 4417 | on reach |
| `apple/Packages/IrisCapture/AGENTS.md` | 3106 | on reach |
| `apple/Packages/IrisUI/AGENTS.md` | 3329 | on reach |
| `apple/IrisMac/AGENTS.md` | 2814 | on reach |
| `scripts/AGENTS.md` | 5247 | on reach |
| all nested files together | 29368 | worst case, never all at once |
| `.claude/rules/apple.md`, `server.md` | 3,843 and 2,881 before, deleted (merged into the nested files) | - |

Loaded on every turn: 127,848 bytes before, 6868 after.
