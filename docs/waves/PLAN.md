# iris-server — the server half of Phase 1

**Goal:** `iris-server` runs on the mini as a LaunchAgent behind `iris.mini.<domain>`. A
memo pushed by a test script (no phone) is received as 10 s segments, concatenated,
transcribed by audio-gateway, sent to a Hermes session, summarized by agent-gateway
`triage`, and handed to a log-only `Notifier`. The whole memo is one trace in HyperDX.
**Gate:** `make check` (oxlint, oxfmt --check, `tsc --noEmit`, `bun test`) green, then
`/review` with its findings resolved. From Wave 4 on, `make verify` too.

Design source: `docs/PLAN.md`. Read it first, especially §System design, §iris-server
modules, §Telemetry. It wins over anything here except the step lists. The Apple apps
are out of scope for this chain: no `apple/` directory and no Xcode. The mini has no
Xcode yet.

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
  CI template: `rb/.github/workflows/check.yml` with `runs-on: [self-hosted, vps]`.

Downstream facts, verified 2026-10-27. Re-check them where a wave depends on one:
- **audio-gateway STT:** `POST /v1/audio/transcriptions`, synchronous multipart,
  OpenAI-compatible. Model `voxtral-mini-transcribe-3-0`, with `language` and `context_bias`
  (Voxtral-only). Response `{text}`. Send the `x-audio-source: iris` header. It is reachable
  from the mini on the VPS instance over the tailnet (`audio-gateway/README.md`). The mini's
  own `:7719` instance is podcast-only.
- **Hermes:** `:8642` on the mini's tailnet IP, `Authorization: Bearer` from
  `op://hermes/gateway/api-server-key`. Call `POST /api/sessions {id, source}`; a 201 or 409
  both mean OK. Then `POST /api/sessions/{id}/chat/stream {message}`, which returns SSE with
  named events. Reference client: `argo/apps/api/src/lib/hermes-upstream.ts`.
- **agent-gateway:** `POST http://127.0.0.1:7705/api/jobs {tool:"triage"|"decide", params}`
  returns a job id. Then `GET /api/jobs/:id` (`agent-gateway/server/routes/jobs.ts`). The
  triage contract is in `agent-gateway/AGENTS.md` (search for "triage").
- **ffmpeg:** at `/opt/homebrew/bin/ffmpeg`. It concatenates segments with the concat
  demuxer, `-c copy`, AAC in m4a.
- **Secrets:** use `secrets-run`, never `op`, on the mini. New refs go into
  `dotfiles-private/headless.refs`. Seeding is `ask-human.sh ask … --cmd 'make secrets-seed'`.

## Wave 1 — Repo foundation            <!-- status: active -->
- [ ] `gh repo create jkrumm/iris --private --source . --push`, then
      `make -C ~/SourceRoot/vps gh-runner-sync`
- [ ] Scaffold `server/` (Bun + Elysia + `bun:sqlite`, TypeScript strict) and the root
      `Makefile` (`check` = `check-server`, which also leaves room for a later
      `check-apple`). Add the oxlint/oxfmt configs, `.gitignore`, and
      `.github/workflows/check.yml` on the self-hosted VPS runner.
- [ ] `server/src/telemetry/` copied from research-gateway with `service.name=iris-server`.
      Add `app.ts` as the composition root, `index.ts` as the entry point, and `GET /health`.
- [ ] Device-token auth (a `IRIS_DEVICE_TOKENS` map of token to device name, the
      audio-gateway caller-token pattern) as an Elysia guard on `/v1/*`, with tests.
- [ ] Write `AGENTS.md` with the required sections: Validate, Deploy (placeholder until
      Wave 4), Verify & Monitor, Gotchas.
**Left behind:**

## Wave 2 — Memo domain + HTTP surface            <!-- status: pending -->
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
      never written into the repo.
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
      (`/otel`). Fill in AGENTS.md Deploy and Verify & Monitor.
**Left behind:**
