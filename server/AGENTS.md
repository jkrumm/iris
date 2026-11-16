# server/ (iris-server: Bun + Elysia + bun:sqlite)

Design is `docs/TDD.md` §3. The skill `iris-server` has the steps for a new pipeline step, adapter or route. Generic TypeScript and
Elysia rules are dotfiles `rules/typescript.md` and `rules/elysia.md` (chain methods for types; mount the auth guard with `as: "scoped"` so it reaches sibling plugins).

## Structure and tests

- A downstream is a port in `src/ports/` with an in-memory fake in `ports/fakes.ts`; its adapter lives in `src/adapters/`. A new port is one entry in `src/compose.ts`, which is the only place a port is chosen (fake under `IRIS_FAKES=1`, real when its env is set, else absent and named in `degraded`), its fake in `fakePorts`, and its env var in `src/env.ts`.
- `src/app.ts` is pure composition (no env, no fs), `src/index.ts` wires the process, and `process.env` is read only in `src/env.ts`.
- Tests are colocated `*.test.ts` with in-memory SQLite and injected fakes, HTTP through `app.handle(new Request())`. No `mock.module` or `spyOn`: they hide the port boundary. Run `make e2e` (needs ffmpeg) for anything on the pipeline.
- Migrations in `src/adapters/sqlite-migrations.ts` are append-only (`PRAGMA user_version`): add one, never edit one.
- `IRIS_FAKES=1` builds every port from fakes. Never set it in production; `scripts/launch.sh` refuses.
- `server/package.json` is imported by `telemetry/otel.ts` for `service.version`; keep it there.
- Log through `telemetry/log.ts`, never `console.log`, and never a token, transcript or reply text.

## Wire contract

- Every request and response shape is a pure TypeBox schema in `src/http/schemas.ts`, because it is the contract source. No Transform: Elysia's `t.Integer` is one, so integers are `t.Number({multipleOf: 1})` (`schemas.test.ts` fails otherwise; the two `t.Numeric` query params are the exception).
- A route or schema change means `make contracts`, updated `contracts/fixtures` (rules in `contracts/AGENTS.md`), a `manifest.json` entry, then `make check-contracts`.
- Elysia mutates the shared TypeBox objects when it composes routes (it adds `additionalProperties: false`), so `src/contracts/export.ts` strips that keyword to stay order-independent.
- Wire JSON is camelCase. Errors are `{error: <code>, message}` through the single `MemoError` mapping in `http/errors.ts`; routes and codes are in `docs/http-api.md`.
- `/v1/*` needs `Authorization: Bearer <token>`; `IRIS_DEVICE_TOKENS` is `token=device,token=device` and empty means every call is 401. A device's identity is the name from the token map, never the request body.
- `POST /v1/telemetry` reads and validates its own body (`parse: "none"`) so a bad token is 401 before any byte is read and an oversized body is cut at 256 KiB.
- SSE has no `Last-Event-ID` replay (clients refetch on reconnect). Long polls and SSE call `server.timeout(request, 0)` to escape Bun's idle timeout.

## Pipeline

- Idempotency: `POST /memos` by id, segments by index and sha256 (same bytes no-op, different bytes 409, the stored file is never overwritten, 409 after `complete`), `complete` repeatable.
- The memo state machine is pure (`memo/memo.ts`): `receiving → received → transcribed → acted → summarized → notified`, `failed(step)` as a side state. Mode `transcribe` skips `act` only: `transcribed → summarized → notified`, so it has a headline too. Hermes decides what a memo is, so the server has no routing; `routed`, `needs_route` and the `route` step exist only so old rows read.
- Every transition goes through `MemoStore.completeStep` (one transaction: compare-and-set, step row, patch). A lost compare-and-set writes nothing. A store error there is bookkeeping, not a step failure: it propagates and logs `runner.bookkeeping_failed`.
- A step handler is a function of (memo, ports) and must be idempotent. `act` is at-least-once: a crash or retry posts another turn into the same Hermes session and repeats its side effects. Keep any new background work behind the shutdown drain (`runner.stop()`, `idle()` before `db.close()`; the LaunchAgent's `ExitTimeOut` of 60 s covers it).
- `summarize` (agw `triage`, plus `llm/summarize` for `transcriptGist`) is optional: when it fails for good the runner calls `store.skipStep` and the memo ends `notified` with no summary. A failing gist call alone is logged (`summarize.gist_failed`) and leaves the summary. Every other step fails the memo.
- Hermes is the only destination, and Iris reaches the software factory only through Hermes: add no factory API call, push or `FACTORY_*` env. Without Hermes configured a memo waits at `transcribed`.
- Downstream env pairs are all-or-nothing: `AUDIO_DOOR_URL` + `AUDIO_DOOR_TOKEN`, `HERMES_URL` + `HERMES_TOKEN`, `AGW_URL` + `AGW_API_SECRET` (URLs are https or a loopback host, else the start fails). A missing pair is named in `/health` `degraded`.
- APNs runs only when `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID` and `APNS_TOPIC` are all set, else the log notifier runs. That state is deliberately not in `degraded`, because a degraded `/health` fails `make verify`.
- Audio-door and agw calls carry `agw-run-id` on every answer; log it and set `agw.run_id` on the span. A hang guard (STT 30 min, speech 2 min, agw 30 min) is not retried: one window, then `POST /retry`. A 401 from a downstream is final, not transient.
- Mermaid blocks and `iris-show` / `iris-doc` fences of a reply are rendered or stored after `act`; a failure there is a log line (`reply.render_failed`, `reply.artifact_invalid`), never a step failure.
- Push: a rejected token never fails the memo (`BadDeviceToken` and 410 clear the stored token only if it is still the one sent to); a transient failure throws `TransientError` so the runner retries. Alerts carry `apns-collapse-id` = memo id and never transcript or reply text.

## Telemetry

- The trace id is the memo UUID without dashes; root span `memo`, a child per step; hand-rolled OTLP, no SDK. An export that fails is a log line, never an error to the client.

## Where the detail is

- `docs/server-design.md`: module map, step results, Hermes decides, threads, `transcribe` mode, shutdown, audio door, agw host, speech and audio caches. Read it before changing the pipeline.
- `docs/server-replies-push.md`: Mermaid and artifact replies, APNs notify rules and transport, Live Activity payload, telemetry relay. Read it before changing `notify/`, `memo/reply-*.ts` or the relay.
- `docs/http-api.md`: every route with its status codes. Read it before changing `src/http/`.
