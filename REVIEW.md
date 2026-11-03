---
# Read by the router (route.py) and by the reviewer. Globs are repo-relative.
none:        [docs/waves/**, docs/research/**, contracts/schema/**, apple/Packages/IrisUI/Package.resolved,
              apple/tools/bun.lock, fixtures/audio/**]
sensitive:   [server/src/adapters/sqlite-migrations.ts, server/src/memo/memo.ts, server/src/memo/runner.ts,
              server/src/memo/purge.ts, server/src/http/auth.ts, server/src/compose.ts,
              server/src/adapters/audio-door-client.ts, server/src/adapters/agw-client.ts,
              server/src/adapters/notifier-apns.ts, server/src/adapters/apns-node.ts,
              apple/Packages/IrisCapture/Sources/IrisCapture/Outbox*.swift,
              apple/Packages/IrisCapture/Sources/IrisCapture/Segment*.swift,
              apple/Packages/IrisCapture/Sources/IrisCapture/CaptureSession.swift,
              "apple/*/*.entitlements", scripts/public-guard.ts, scripts/launch.sh, scripts/mini-deploy.sh,
              launchd/**, .github/**]
nits: 3
---
# REVIEW.md — iris

What failure looks like here:

- **A recording is lost or doubled.** A memo is uploaded as 10 s segments: segment rotation, the outbox and `complete` in
  `IrisCapture` (`Outbox*.swift`, `Segment*.swift`, `CaptureSession.swift`) must survive a hung close, a cancelled take, a
  connection switch and a relaunch. A segment is idempotent by index + sha256; work stays bound to the server it was queued for.
- **A pipeline step is not idempotent.** The memo state machine in `memo/memo.ts` is pure; a step handler (`pipeline/steps.ts`) is
  a function of (memo, ports) that may run twice (`act` is at-least-once); transitions go through `MemoStore.completeStep` in one
  transaction. A missing CAS, a double notification without `apns-collapse-id`, or work started outside the runner's drain.
- **The wire contract drifts.** `http/schemas.ts` is the one shape source; a route change needs `make contracts`, a fixture, a
  `manifest.json` entry, and the Swift decoder. Wire JSON is camelCase, errors are `{error, message}` through the one `MemoError` map.
- **A downstream is reached around its port.** Ports in `ports/` with a fake in `ports/fakes.ts`; `compose.ts` is the only place a port is
  chosen and `env.ts` the only reader of `process.env`. One door client, one agw client; no redirects, a hang guard, caller headers set.
- **Auth or data exposure.** The device-token guard in `http/auth.ts` covers every route; a memo of another device is 409/404, never
  readable; soft-deleted memos stay hidden and purge only after the undo window; `IRIS_FAKES` never runs in production.
- **A migration breaks the database.** `sqlite-migrations.ts` is `PRAGMA user_version`-gated and forward-only; a changed past
  migration or a non-transactional data move loses memos.
- **The public repo leaks.** Hostnames, IPs, tailnet names, tokens, device or team ids, APNs keys or e-mails in any tracked file,
  including entitlements, fixtures and docs (`scripts/public-guard.ts` must still catch them).
- **The UI hangs the main actor.** Apple code that blocks the main actor on audio, file or telemetry work, an unbounded wait on the
  microphone or `finishWriting`, or a hardcoded string outside the String Catalog (`scripts/check-strings.ts`).

Skip: formatting, naming taste, lint-level remarks, test style. Evidence is always `file:line`.
