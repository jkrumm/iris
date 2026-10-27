# iris — Agent Instructions

Voice channel into the agent platform. A memo recorded on a phone is uploaded as 10 s segments,
transcribed, routed to Hermes, summarized and notified. **`docs/PLAN.md` is the design**
(system design, modules, telemetry); `docs/waves/PLAN.md` is the implementation chain.
Today only `server/` exists (Bun + Elysia + `bun:sqlite`, TypeScript strict); the Apple apps
come later under `apple/`.

## Layout

- `server/src/app.ts` — composition root: wires adapters into ports, nothing else.
- `server/src/index.ts` — entry point (listen, signals, OTel flush).
- `server/src/http/` — routes and the device-token guard (`/v1/*`).
- `server/src/telemetry/` — `otel.ts`, `otel-format.ts`, `log.ts`, copied from research-gateway
  (hand-rolled OTLP JSON, no SDK). The trace id is the memo UUID with dashes stripped.
- `server/src/env.ts` — the only place `process.env` is parsed.

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
- **Secrets on the mini:** `secrets-run`, never `op`.
- `server/package.json` is imported by `telemetry/otel.ts` for `service.version`; keep it there.
