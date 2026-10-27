---
description: Iris invariants for the Bun + Elysia server (ports and adapters, contracts, runner, public repo)
paths: ["server/**"]
---

# Iris Server Invariants

Generic TypeScript is `rules/typescript.md` (dotfiles); Elysia is `rules/elysia.md`. Design: `docs/TDD.md` §3.

- **Ports and adapters.** A downstream is a port in `src/ports/` with an in-memory fake in `ports/fakes.ts`; the adapter lives in
  `src/adapters/`. `app.ts` is a pure composition (no env, no fs); `index.ts` and `compose-fakes.ts` are the only composition roots.
  `process.env` is read only in `env.ts`. Tests inject fakes and use in-memory SQLite, HTTP via `app.handle(new Request())`; no
  `mock.module`, no `spyOn`.
- **The memo state machine is pure** (`memo/memo.ts`): states `receiving → received → transcribed → routed | needs_route → acted →
  summarized → notified`, `failed(step)` as a side state. Transitions go through `MemoStore.completeStep` (one transaction: CAS, step
  row, patch). A step handler is a function of (memo, ports) and must be idempotent; `act` is at-least-once (documented in AGENTS.md).
- **The wire format is the contract.** Every request and response shape is a pure TypeBox schema in `http/schemas.ts` (no Transform;
  integers are `t.Number({multipleOf: 1})`). A route change means `make contracts`, updated `contracts/fixtures`, a `manifest.json`
  entry, `make check-contracts`. Wire JSON is camelCase; errors are `{error: <code>, message}` through the single `MemoError` mapping.
- **Idempotency:** `POST /memos` by id, segments by index + sha256, `complete` repeatable, notifications carry `apns-collapse-id`.
- **Telemetry:** the memo UUID without dashes is the trace id; root span `memo`, a child per step; hand-rolled OTLP, no SDK. Log
  through `telemetry/log.ts`, never `console.log` in server code.
- **Shutdown drains** the runner (`runner.stop()`, `idle()`) before `db.close()`; the LaunchAgent's `ExitTimeOut` (60 s) covers it.
  Keep any new background work behind that drain.
- **Never set `IRIS_FAKES` in production** (`launch.sh` refuses). Secrets only through `secrets-run` / `op://` refs in `.env*.tpl`.
- **Public repo:** no real hostnames, IPs, tailnet names, tokens or emails in any tracked file (`make guard`). Placeholders only.
- **Gate:** `make check` (lint, format, tsc, tests, contracts, guard), `make e2e` for anything on the pipeline. Skill: `iris-server`.
