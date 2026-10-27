---
name: iris-server
description: Work on iris-server (Bun + Elysia + bun:sqlite) — ports and adapters rules, adding a pipeline step or an adapter, the contracts workflow, running the fake-booted e2e. Use before changing anything under server/, contracts/ or scripts/send-memo.ts.
---

# iris-server

Design: `docs/TDD.md` §3. Invariants: `.claude/rules/server.md`. Every command below was run on the mini (2026-10-27).

## Gate

```bash
make check        # server (oxlint, oxfmt, tsc, bun test) + contracts + guard (+ check-apple where Xcode exists)
make e2e          # boots server/src/index.ts with IRIS_FAKES=1 + temp IRIS_DATA, send-memo.ts must reach `notified`  (ran: "e2e ok")
make format       # oxfmt
```

## Add an adapter for a downstream

1. Port in `server/src/ports/<name>.ts` (small interface, no vendor types), fake in `ports/fakes.ts`.
2. Adapter in `server/src/adapters/<name>.ts`, tested against a fake HTTP/unix server, never the real downstream.
3. Optional env var in `env.ts` (empty = unset); wire it in `index.ts` and its fake in `compose-fakes.ts`. A port that is left out means
   no handler: the memo parks and `/health` lists the step in `degraded`.

## Add or change a step

`server/src/pipeline/steps.ts` (`createStepHandlers`) holds the handlers, a pure function of (memo, ports). Return the patch the step owns;
`MemoStore.completeStep` writes it with the state change in one transaction. Handlers are idempotent (`act` is at-least-once). Add the new
column through an append-only migration in `adapters/sqlite-migrations.ts`, never edit an old entry. Every step gets a child span of
`withRootSpan("memo")` from the runner; do not open your own root.

## Change the API: contracts workflow

```bash
# 1. edit server/src/http/schemas.ts (pure TypeBox, no Transform) and the route
make contracts          # regenerates contracts/schema/*.json from the TypeBox schemas
# 2. add/update contracts/fixtures/<name>[.<variant>].json (realistic, camelCase, fixed ids/timestamps, no real hosts) and manifest.json
make check-contracts    # schema export equals contracts/schema, fixtures validate, manifest lists exactly the served routes
```

Then the Swift side: `IrisCore` decodes every fixture and a fixture without a mapped type fails `swift test`. Commit the server change and the
fixtures together; the Apple mapping may follow in its own commit.

## Debug

- `bun test <path>` for one file (from `server/`). HTTP is tested with `createApp({...})` from `http/test-support.ts` and `app.handle(new Request(...))`.
- `bun scripts/send-memo.ts <audio> --mode hermes --wait 120` drives a real server (needs `IRIS_URL`, `IRIS_TOKEN`); `make smoke` does it against
  production with the German recording. A failing memo: skill `memo-debug`.
- Never start a dev server by hand to "look"; `make e2e` boots and kills its own.
