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
  (idempotent step runner), `service.ts` (`MemoService`, what HTTP calls), `events.ts` (in-process
  pub/sub), `errors.ts` (`MemoError` codes), `test-support.ts` (fake audio, seeded memos).
- `server/src/adapters/` — `sqlite.ts` (+ `sqlite-migrations.ts`, `PRAGMA user_version`), `audio-fs.ts`.
- `server/src/ports/` — `audio.ts`, `clock.ts` (system, fixed and manual clocks).
- `server/src/http/` — `auth.ts` (device-token guard), `memos.ts` and `events.ts` (route plugins),
  `errors.ts` (the one `MemoError` → status mapping), `serialize.ts` (the one wire-shape mapping, camelCase),
  `test-support.ts` (in-memory app for `app.handle` tests).
- `server/src/telemetry/` — `otel.ts`, `otel-format.ts`, `log.ts`, copied from research-gateway
  (hand-rolled OTLP JSON, no SDK). The trace id is the memo UUID with dashes stripped.
- `server/src/env.ts` — the only place `process.env` is parsed.

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
| `GET /events` | SSE: `ready`, `memo.updated` per state change, plus `memo.done` when result-ready, `: keepalive` every 15 s |

Codes: not_found 404, conflict / bad_state 409, missing_segments 422, too_large 413, bad_request 400.
Wire JSON is camelCase.
States: `receiving → received → transcribed → routed | needs_route → acted → summarized → notified`,
with `failed(step)` as a side state.

## Validate

`make check` — oxlint, `oxfmt --check`, `tsc --noEmit`, `bun test` (server). CI runs
`make check-server` on `[self-hosted, vps]`. `make format` applies oxfmt.

Tests are colocated `*.test.ts`. Ports and adapters: dependencies are injected, tests use
in-memory SQLite and fake ports, no `mock.module` / `spyOn`, HTTP via `app.handle(new Request())`.

## Deploy

Placeholder until Wave 4: LaunchAgent `com.jkrumm.iris` from the deploy clone `~/.iris/app`
(data in `~/.iris/data`), behind `iris.test` on the mini's Caddy. Direct-to-master.

## Verify & Monitor

Placeholder until Wave 4. `GET /health` is public and returns `{status, degraded[]}`;
`degraded` lists `otel` (no OTLP endpoint) and `device-tokens` (none configured). Traces and
logs go to HyperDX with `service.name=iris-server`.

## Gotchas

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
- **The runner has no handlers until Wave 3:** memos stop after `received`; `index.ts` logs
  `runner.no_handlers_registered`.
- **SSE** has no `Last-Event-ID` replay; clients refetch the list on reconnect.
- **Long polls and SSE** call `server.timeout(request, 0)` to escape Bun's idle timeout.
- **Secrets on the mini:** `secrets-run`, never `op`.
- `server/package.json` is imported by `telemetry/otel.ts` for `service.version`; keep it there.
