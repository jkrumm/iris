# iris

Voice channel into the agent platform: a memo recorded on a phone is uploaded as 10 s segments, transcribed, handed to Hermes (which decides what it is and acts) and the owner is notified. A public monorepo: `server/` (Bun + Elysia + `bun:sqlite`, runs on the mini), `apple/` (iOS app, Mac app, Swift packages), `web/` (the artifact page the app's WebView loads), `contracts/` (the wire contract both sides test against), `scripts/`, `launchd/`. `docs/TDD.md` is the design and the code is the truth for shipped behaviour; `docs/PRD.md` is the product. New work is a software-factory Issue (`factory issue new --repo iris --title "<title>"`). The finished wave chain is archived in `docs/waves/archive/PLAN.md`.

A nested `AGENTS.md` loads when you work in its directory. Read the pointer lines at the end before you change code there.

## Requirements

- Public repo: no real hostnames, IPs, tailnet names, tokens or personal emails in any tracked file. `make guard` and the pre-commit hook enforce it; the real-domain literals live in the untracked `~/.config/iris/guard-extra.txt`. Write `<domain>`, `iris.mini.<domain>`, `example.com`; `op://` refs in `.env*.tpl` are fine. CI runs on hosted runners.
- Trust model: every device token is trusted equally, and memos, history and SSE are shared across devices on purpose (the Mac shows the phone's memos). Ownership is checked only on create.
- Contracts are regenerated, not hand-edited: a route or schema change is `make contracts`, updated `contracts/fixtures`, then `make check-contracts`. The server changes first and Swift decodes the fixtures after.
- Generated files, never edited by hand: `apple/Iris.xcodeproj` (edit `apple/project.yml`, run `make generate`), `contracts/schema/`, the `IrisUI` Theme tokens (`make theme`), and the web bundle in `apple/Packages/IrisUI/.../Resources/Artifact/` (`make web-build`, committed with its source).
- Secrets on the mini come through `secrets-run`, never `op`. `IRIS_FAKES` is never set in production.
- Never start a dev server for a human to look at. A simulator is fine; shut it down after (`make sim-down`).
- There are no MCP servers (TDD D17): UI automation is `scripts/mbm`, a pinned `mobilebuildmcp` CLI; Apple's own CLIs do the rest.

## Validate

- A lead runs `make check-fast`: server, contracts, strings, web without e2e, guard, the Apple theme drift and lint, and package tests only when `apple/` differs from `origin/master`. It starts no simulator and no `xcodebuild`.
- CI runs the full gate on the PR head (`check.yml`, and `apple.yml` on the hosted `xcode-27` image for Apple paths). Run `check-apple`, `snapshots` or `uitest` locally only to reproduce a CI failure, as one targeted run.
- `make e2e` (needs ffmpeg) runs the pipeline against a fake-booted server; run it for anything on the pipeline. `make merge-guard` runs right before merging a PR.
- `make help` lists every target in one line; per-target detail, the Apple CI jobs and the uitest subset are in `docs/validate.md`.
- Fix errors in changed files only. `make format` applies oxfmt.

## Time and cost

- Locally, at most one targeted Apple run per change. Every heavy Apple target (`check-apple`, `build-apple`, `test-packages`, `snapshots`, `uitest`, `sim`, `run-sim`, `screenshot`, `ui-snapshot`, `proof-apple`, `device`, `testflight`, `mac-release`) holds the one Apple lock through `scripts/apple-slot`, so a second job waits or exits 75.
- A stock iOS 27 simulator holds about 11 GiB and peaks near 19 GiB under a UI test; two of them put the mini into swap. Run one simulator, slimmed by `scripts/sim-slim`.
- `make uitest` without `ONLY="<Class>[/<test>]"` refuses outside CI. A Mac archive with notarization can run past 30 minutes.

## Deploy

`project.yaml` is the factory manifest (deploy mode `make`, target `mini`, verify `make verify`). A push to master deploys: the mini's poller (`com.jkrumm.iris-deploy`, every 120 s) deploys `origin/master` once `check` is green on that sha and no memo is mid-step, and restarts the server only for runtime paths. `make deploy` runs one tick now and `make version` prints the deployed sha. The server runs from the deploy clone `~/.iris/app`, never from this checkout, on `127.0.0.1:7730` (doors `iris.test` local, `iris.mini.<domain>` tailnet). A bad deploy is fixed forward with a new commit on master. The same poller starts the TestFlight and Mac release hooks from `apple/**` commits: `scripts/AGENTS.md`.

## Verify & Monitor

- `make verify` exits 0 iff `GET /health` answers `status: ok` (`{status, degraded[], inflight, receiving}`) and the audio door (`http://127.0.0.1:7792/health`) and the agent-workflows host (`http://127.0.0.1:7791/health`) do too. `degraded` names `otel`, `device-tokens` and the steps without a downstream.
- `make smoke` sends a real 96 s German recording through the pipeline to `notified`. It prints the memo's `kind` and `actions`: no `kind` means the reply had no valid ```iris block (`hermes.meta_invalid` in `make logs`).
- `make logs` tails production logs, `make launchd-status` shows the agents, `make launchd-restart` refuses while `inflight > 0` or `receiving > 0` (`FORCE=1` overrides).
- Traces and logs are in HyperDX (query via `/otel`, prod): `service.name=iris-server` (`iris-ios` and `iris-macos` for the apps), trace id = the memo UUID without dashes, root span `memo`, a child per step. Skill `memo-debug` follows one memo end to end.

## Gotchas

Traps live in the directory they bite, so a trap you meet while working goes into the nearest nested `AGENTS.md` below, never here unless every task in the repo needs it. A file at its budget (root 12,000 bytes, nested 8,000) takes a line only by losing one. A feature's design and history go to `docs/`, behind one pointer line.

## Where to look

Skills in `.claude/skills/` load by their descriptions; `.claude/rules/swift.md` is the generic Swift rule. Nested files:

- `server/AGENTS.md`: changing server code, the pipeline, an adapter, a route or push. It points at `docs/server-design.md` (pipeline behaviour, module map), `docs/server-replies-push.md` (Mermaid and artifact replies, APNs, relay) and `docs/http-api.md` (every route with its codes).
- `contracts/AGENTS.md`: editing a fixture, a schema or the manifest.
- `web/AGENTS.md`: changing the artifact page. Reasoning, CSP and measurements: `docs/web-renderer.md`.
- `apple/AGENTS.md`: any Apple work. Then `apple/Packages/IrisCapture/AGENTS.md` for capture and the outbox (`docs/apple-capture.md`), `apple/Packages/IrisUI/AGENTS.md` for shared views, spacing and artifacts, `apple/IrisMac/AGENTS.md` for the Mac app (`docs/mac-app.md`). iPhone screens: `docs/apple-app.md`.
- `scripts/AGENTS.md`: drivers, the deploy poller, release hooks, the Apple lock, device scripts. Detail: `docs/release-and-ops.md`, `docs/device.md` (the paired phone and its signing), `docs/validate.md`.
