# iris — Agent Instructions

Voice channel into the agent platform. A memo recorded on a phone is uploaded as 10 s segments,
transcribed, routed to Hermes, summarized and notified. **`docs/TDD.md` is the design**
(system design, modules, telemetry; `docs/PRD.md` is the product); `docs/waves/PLAN.md` is the implementation chain.
Today only `server/` exists (Bun + Elysia + `bun:sqlite`, TypeScript strict); the Apple apps
come later under `apple/`.

## Layout

- `server/src/app.ts` — `createApp({deviceTokens, memos, degraded?, sseKeepaliveMs?})`: mounts routes, no env/fs.
- `server/src/index.ts` — entry point and production composition (SQLite, audio-fs, runner, service),
  listen, background `driveAll`, signals, DB close, OTel flush.
- `server/src/memo/` — domain: `memo.ts` (states, steps, transitions), `store.ts` (port), `runner.ts`
  (idempotent step runner, concurrency-bounded `driveAll`, `idle()`), `service.ts` (`MemoService`, what HTTP calls), `media.ts`
  (`MemoMedia`: the combined recording and the spoken result, both disk-cached and single-flight), `events.ts` (in-process
  pub/sub), `errors.ts` (`MemoError` codes, `configured()` for optional subsystems), `test-support.ts` (fake audio, seeded memos).
- `server/src/pipeline/steps.ts` — `createStepHandlers`: the five step handlers, each a pure function
  of (memo, ports); a handler is registered only when its port is provided.
- `server/src/adapters/` — `sqlite.ts` (+ `sqlite-migrations.ts`, `PRAGMA user_version`), `sqlite-devices.ts`
  (`DeviceStore`, same db), `audio-fs.ts` (segments + `combined.m4a`), `speech-fs.ts` (`<id>.mp3` + `<id>.txt`),
  and the downstream adapters (audio-gateway transcriber + ffmpeg combiner, `audio-gateway-speaker.ts`, Hermes, agw,
  `herdr.ts` over the unix socket, log notifier), and the APNs pair: `notifier-apns.ts` (`Notifier` over an `ApnsTransport`)
  and `apns-node.ts` (the transport on `@parse/node-apn`; `apns-test-support.ts` generates test keys and certs).
- `server/src/ports/` — `audio.ts` (`AudioStore`, `AudioCombiner`, `Recording`), `clock.ts` (system, fixed and manual clocks),
  `transcriber.ts`, `speaker.ts` (+ `SpeechCache`), `devices.ts` (`DeviceStore`: devices, APNs tokens, Live Activity tokens),
  `herd.ts`, `destination.ts`, `summarizer.ts`, `notifier.ts` (`notify` + best-effort `phase`),
  `apns.ts` (`ApnsTransport`), `fakes.ts` (in-memory fakes of the ports, incl. `fakeApnsTransport`).
- `server/src/notify/` — `payloads.ts` (pure alert / Live Activity builders), `phases.ts` (`bindPhaseUpdates`: memo events →
  `notifier.phase`), `select.ts` (`selectNotifier`: APNs or log, plus the transport's `close`),
  `lifecycle.ts` (`createNotifyLifecycle`: stop / idle / close for shutdown).
- `server/src/http/` — `auth.ts` (device-token guard), `memos.ts`, `devices.ts`, `media.ts` (audio + speech, `Range`),
  `herd.ts` and `events.ts` (route plugins), `schemas.ts` (every request/response shape as pure TypeBox, exported for the
  contracts), `errors.ts` (the one `MemoError` → status mapping), `serialize.ts` (the one wire-shape mapping, camelCase),
  `test-support.ts` (in-memory app for `app.handle` tests).
- `server/src/telemetry/` — `otel.ts`, `otel-format.ts`, `log.ts`, copied from research-gateway
  (hand-rolled OTLP JSON, no SDK). The trace id is the memo UUID with dashes stripped.
- `server/src/env.ts` — the only place `process.env` is parsed.
- `server/src/contracts/` — `registry.ts` (contract name → TypeBox schema), `export.ts` (TypeBox → JSON Schema),
  `manifest.ts` (zod shape of `contracts/manifest.json`), `routes.ts` (the real app's route table),
  `check.ts` (`checkContracts`), `cli.ts` (`export` | `check`), `conformance.test.ts` (live app vs contracts).
- `contracts/` — the wire contract Swift decodes: `schema/<name>.json` (generated, JSON Schema 2020-12),
  `fixtures/<name>[.<variant>].json` (hand-written, valid against schema `<name>`), `manifest.json` (every route
  with its schema names, status codes and media types; binary and SSE routes included).
- `server/src/compose-fakes.ts` — `composeFakes()`: every downstream port as an in-memory fake (`IRIS_FAKES=1`).
- `scripts/` — `send-memo.ts` (driver), `e2e.ts` (`make e2e`), `smoke.sh`, `launch.sh` (LaunchAgent entry), `mini-deploy.sh` (poller tick);
  `launchd/` — plist templates; `fixtures/audio/` — the German smoke recording.

## HTTP API

All under `/v1`, `Authorization: Bearer <token>`. Errors: `{error: <code>, message}`.

| Route | Result |
|-|-|
| `POST /memos` `{id, mode, startedAt}` | 201 memo; 200 if it exists for this device; 409 other device |
| `PUT /memos/:id/segments/:n` raw `audio/mp4` bytes | 200, idempotent by sha256 (same sha no-op, different sha 409); 413 over `IRIS_MAX_SEGMENT_BYTES`; 409 after `complete` |
| `POST /memos/:id/complete` `{segmentCount}` | 202 memo (repeat too); 422 `missing_segments` + `missing: [...]` |
| `POST /memos/:id/retry` `{from}` | 202 memo; 409 unless `failed` |
| `GET /memos?limit&cursor` | `{items, nextCursor}`, newest first |
| `GET /memos/:id` | memo + `steps` timeline + `segmentCount`; 404 unknown |
| `GET /memos/:id/result?wait=<s>` | 200 once result-ready, else 202 after the wait (0..600, default 0) |
| `POST /devices/register` `{name, platform: ios\|macos, apnsToken?, apnsEnv?, pushToStartToken?}` | 200 `{device, name, platform, apnsEnv, hasApnsToken, hasPushToStartToken, registeredAt}`; upsert by the authenticated device |
| `PUT /memos/:id/activity-token` `{token}` (hex) | 204, replaces the stored token; 404 unknown memo |
| `GET /memos/:id/audio` | `audio/mp4`, concatenated on first request and cached; `Range` → 206 / 416; 404; 409 while `receiving` |
| `GET /memos/:id/speech` | `audio/mpeg` TTS of `summary.spoken`, else `replyText`, cached; 404; 409 with neither; 503 without audio-gateway |
| `GET /herd` | `{tabs: [{id, repo, label, agentState, lastActivity}]}` from herdr; 503 without `HERDR_SOCKET` or when herdr is unreachable |
| `GET /events` | SSE: `ready`, `memo.updated` per state change, plus `memo.done` when result-ready, `: keepalive` every 15 s |

Codes: not_found 404, conflict / bad_state 409, missing_segments 422, too_large 413, bad_request 400, unavailable 503.
Wire JSON is camelCase.
States: `receiving → received → transcribed → routed | needs_route → acted → summarized → notified`,
with `failed(step)` as a side state.

## Validate

`make check` — `check-server` (oxlint, `oxfmt --check`, `tsc --noEmit`, `bun test`), `check-contracts` and
`guard` (public-repo scan). CI runs `make check` then `make e2e` on `ubuntu-latest` (public repo, hosted
runners). `make format` applies oxfmt.

`make e2e` (`scripts/e2e.ts`, CI after `check`, needs ffmpeg) boots `server/src/index.ts` on a free port with
`IRIS_FAKES=1` and a temp `IRIS_DATA`, runs `send-memo.ts` on the smoke recording (must reach `notified`), then probes
`/devices/register`, `/activity-token`, `/audio` (Range 206), `/speech` (audio/mpeg) and `/herd`. The server is always killed.

**`IRIS_FAKES=1`** (boolean-ish, empty = off) builds every port from `composeFakes()`, ignoring downstream env, and keeps the
real ffmpeg combiner. `/health` is `degraded` with `"fakes"`, boot logs `server.fakes_mode`, and `scripts/launch.sh`
refuses to start when `IRIS_FAKES` is set. Never set it in production.

`make check-contracts` — the exported JSON Schemas equal `contracts/schema` byte for byte, every fixture validates
(ajv 2020, strict), and `manifest.json` lists exactly the routes `createApp(...).routes` serves. `make contracts`
regenerates `contracts/schema`. `make check` and CI do not run it yet (the contract tests run inside `bun test`).

Tests are colocated `*.test.ts`. Ports and adapters: dependencies are injected, tests use
in-memory SQLite and fake ports, no `mock.module` / `spyOn`, HTTP via `app.handle(new Request())`.

**Harness:** `bun scripts/send-memo.ts <audio-file>` is the end-to-end driver. It splits the file into
10 s m4a segments with ffmpeg, then creates, uploads, completes and long-polls a memo like the phone
does, and prints transcript, reply, summary, step timings and cost. Env: `IRIS_URL` (default
`http://127.0.0.1:7730`), `IRIS_TOKEN` (required); flags `--url --token --mode auto|journal|hermes|tab
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
- `HERMES_URL` is composed in `launch.sh` from `HERMES_HOST` + `HERMES_PORT`.

## Verify & Monitor

- `make verify` — exit 0 iff `GET /health` answers `status: ok` (public; `{status, degraded[], inflight}`).
  `degraded` lists `otel`, `device-tokens` and steps without a downstream (`transcribe`, `act`, `summarize`).
- `make smoke` — a real German 96 s recording (`fixtures/audio/de-90s.m4a`) through the pipeline to
  `notified`. `IRIS_URL=https://iris.mini.<domain> make smoke` goes through the tailnet door. Uses the
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
  `HERMES_TOKEN`, `HERDR_SOCKET` (`launch.sh` sets it on the mini). Without one, `/health` lists `transcribe` /
  `summarize` / `act` / `speech` / `herd` in `degraded`; the first three park memos before that step, the last two
  answer 503 `unavailable`. `route` always yields `hermes` until Phase 2.
- **`act` is at-least-once:** a crash or restart mid-`act` replays the step, which posts a second turn
  into the same Hermes session. Shutdown keeps the window small: `app.stop(true)`, `runner.stop()` (the
  running step finishes, no further step or queued memo starts), `notifyLifecycle.stop()`, `await runner.idle()` + the in-flight
  Live Activity pushes under one 30 s drain deadline (`shutdown.drain_timeout` logs the in-flight memo ids), the APNs transport `close()`, `db.close()`, then a separate 2 s OTel
  flush deadline. The LaunchAgent's `ExitTimeOut` is 60 s to cover it.
- **Devices:** identity is the authenticated device name from the token map, never the body (`name` is a display label).
  `registerDevice` keeps a stored token when the field is omitted or `""` and clears it only on explicit `null`. The
  response reports token presence, never the tokens. `DeviceStore.getDevice` + `getActivityToken` are what the APNs
  notifier reads. Migrations are append-only: `devices` and `activity_tokens` (cascades with the memo) are entry 4.
- **Audio and speech are derived, disk-cached and single-flight:** the recording is `<audio>/<id>/combined.m4a` (mono 16 kHz
  AAC from `ffmpegConcat`, built on the first request; removed with the segments), speech is
  `<IRIS_DATA>/speech/<id>.mp3` with the spoken text in `<id>.txt`, so a retry that changes the text re-synthesizes
  instead of replaying stale audio. A failed combine or synthesis caches nothing. `/audio` honours a single `bytes=` range;
  multi-range and malformed headers get the whole body, a range past the end gets 416.
- **Speech request** to audio-gateway: `POST /v1/audio/speech {input, response_format: "mp3"}` with `x-audio-source: iris`.
  No `model` or `voice`: the gateway owns both and detects the language. A non-2xx is 503 `unavailable`.
- **herdr:** one connection per request, newline-delimited JSON, `session.snapshot` (verified on herdr 0.9.3, protocol 22).
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
  Transient failures (status 0, 408, 429, 5xx, 403 ExpiredProviderToken) throw, so notify fails and `POST /retry` re-drives
  it (a retry re-sends both pushes; the alert carries `apns-collapse-id` = memo id, so a re-send replaces the banner instead of duplicating it). `phase` (Live Activity `update`, priority 5) is bound to memo events by
  `bindPhaseUpdates`: not for `receiving` or `notified`, serialised per memo, latest state wins, errors logged only.
- **APNs transport:** node-apn builds the ES256 JWT with `jsonwebtoken` and regenerates it when its `iat` is 3300 s (55 min)
  old, checked per request (Apple: not <20, not >60 min); it retries 408/429/5xx and ExpiredProviderToken 3x. We cap in-flight
  streams at 10 (Bun ignores `peerMaxConcurrentStreams`) and send the first request per environment alone (Apple allows one
  stream until a valid token lands; a status-0 failure re-arms that). `config.port` (443) is passed to `http2.connect` and Bun
  honours it over the URL, so a test server needs `address` and `port` both. Not verified: real Apple hosts and GOAWAY JSON.
  node-apn emits a harmless `MaxListenersExceededWarning` (one `timeout` listener per stream on the session) above 10 streams.
- **Live Activity contract (Swift side):** payload `aps` is `{timestamp, event, "content-state"}` (+ `dismissal-date` on `end`,
  now + 15 min). `ContentState` is plain camelCase Codable: `phase` (`processing` | `needsRoute` | `done` | `failed`),
  `routeChip?`, `headline?` (≤ 60), `hasReply`. `inputName` is never sent: the client keeps it device-side and must declare it
  optional. Alerts carry the route chip + headline only (never transcript or reply), `category: MEMO_DONE`, `thread-id: memo`,
  `mutable-content: 1` and a top-level `memo` id.
- **Bookkeeping failures** (`completeStep` throws after a handler ran) log `runner.bookkeeping_failed`
  and propagate; the step row stays `running` and the memo keeps its state until the next `driveAll`.
- A stored `summary_json` that fails the zod `Summary` schema reads as `null` with a `memo.summary_invalid` log.
- **SSE** has no `Last-Event-ID` replay; clients refetch the list on reconnect.
- **Long polls and SSE** call `server.timeout(request, 0)` to escape Bun's idle timeout.
- **Secrets on the mini:** `secrets-run`, never `op`.
- `server/package.json` is imported by `telemetry/otel.ts` for `service.version`; keep it there.
