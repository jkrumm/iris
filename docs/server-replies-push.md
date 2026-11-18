# Server replies, push and telemetry relay

Mermaid and artifact replies, APNs notify rules and transport, the Live Activity payload and the telemetry relay. Rules to follow: `server/AGENTS.md`; payload shapes: `contracts/`.

- **Mermaid replies:** after `act` has the reply, `memo/reply-assets.ts` renders every top-level ```mermaid fence through the `DiagramRenderer` port
  (production `adapters/diagram-pele.ts`: Pele for SVG, resvg-js for PNG at 2x, light and dark with the basalt colours resolved into the SVG) and stores four files per block
  under `<IRIS_DATA>/assets/<memo>/<uuid>`, staged with the store (`stageReplyAssets`, no row yet) and written to `reply_assets` by the `completeStep` that commits that reply; the wire carries `replyBlocks` (omitted when empty: `{index, kind, width, height, svg, png}`, each
  `{light, dark}` asset ids; `index` counts the reply's mermaid fences from 0). A block Pele rejects stays a code block (`reply.render_failed`; a failed file write is `reply.store_failed`; more than 12 blocks `reply.blocks_capped`; no asset, never a step failure),
  a changed reply re-renders and prunes the old files once its commit wins; a lost compare-and-set leaves the earlier reply's rows and files and removes only the new attempt's files; a boot sweep (`ReplyAssets.backfill`, 50 memos per start) renders older replies that have a fence and no rows; a boot sweep (`ReplyAssets.sweep`, 200 memo directories per start, `listMemos` stat-ing 32 at a time, skipping a directory that vanished and skipping and logging (`reply.sweep_failed`, its name) one that cannot be stat-ed; `reply.sweep` logs `skipped`, the directories the limit left, null when the listing failed) removes asset files no row names and no in-flight attempt holds (a crash between commit and prune), logging them as `reply.orphans_removed`; a memo whose blocks Pele all refused (not a failed file write) carries `memos.reply_assets_failed` (migration 13) and is skipped until its reply changes; the purge removes files before rows. Library choice and why: TDD §3 "Reply assets".

- **Reply artifacts:** `memo/reply-artifacts.ts` also reads two typed top-level fences of the reply (the fence stays in `reply_text`): ```` ```iris-show ```` (one JSON spec, a strict zod 4 union `table|chart|stat|list|callout`, body ≤ 64 KiB; exported as the contract `artifacts.show-spec`) and ```` ```iris-doc title="…" format=markdown|html ```` (a document stored as is, body ≤ 200 KiB). They ride the Mermaid lifecycle (staged in `sync`, rows in `reply_artifacts` (migration 17) replaced by the `completeStep` that commits the reply, pruned, purged, swept) and are listed in `replyArtifacts` (`{index, kind, title?, format?, assetId, bytes}`, omitted when empty; `index` counts the fences of that kind, invalid ones included). An invalid fence stays a code block and logs `reply.artifact_invalid` (`reason`: `too_large|bad_json|bad_spec|bad_info|empty`; `bad_spec` adds zod `issues` as path and code only); more than 12 per kind log `reply.artifacts_capped`. Not backfilled. Speech says the artifact's title instead of reading it. Detail: `docs/TDD.md` §Reply artifacts.

- **APNs** (`APNS_KEY_P8` PEM, literal `\n` or spaces for newlines allowed, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` = bundle id): the
  APNs notifier runs only when all four are set (else the log notifier), and that is deliberately not in `degraded` (the log
  notifier is the dev-setup state; a degraded `/health` fails `make verify`). Boot logs `notifier.selected`.
  Environment per push is `device.apnsEnv`, `sandbox` when null; with a null `apnsEnv`
  a BadDeviceToken (likely a production token sent to the sandbox) is logged with a hint and the token is kept, so only
  an explicitly registered env makes BadDeviceToken clear it (410 / Unregistered always do, via the conditional `clearApnsToken`). `notify` announces a memo with a Live Activity in two pushes (Issue 223: Apple documents the alert sound for `update`, not `end`): a final `update` (phase done) when the memo has an
  activity token (it carries `aps.alert` {kind chip or "Iris", headline, `sound: "default"`}, so the device lights up and plays the sound; no separate banner, owner 2026-11-05, TDD §3 notify), then the `end` without an alert; else the alert push
  (if the device has an `apnsToken`; also the fallback when the done update is refused for good, then no `end` follows); neither registered logs `notify.no_token` and succeeds. A transient failure of either Live Activity push throws without sending the alert, and the retry sends both again (the sound can repeat).
  Every delivered push logs `notify.apns_sent` (kind, push_type, priority, event, alert_present, sound, status; no text). A rejected token never fails the memo: `notify.apns_rejected` is logged, and BadDeviceToken / 410 Unregistered clear the
  stored token (only if it is still the one we sent to); other 4xx (e.g. 403 InvalidProviderToken) are logged, tokens kept.
  Transient failures (status 0, 408, 429, 5xx, 403 ExpiredProviderToken) throw a `TransientError`, so the runner retries notify twice (2 s, 8 s) and then fails it for `POST /retry`
  (a retry re-sends the push by the same rule; the alert carries `apns-collapse-id` = memo id, so a re-send replaces the banner instead of duplicating it). `phase` (Live Activity `update`, priority 5) is bound to memo events by
  `bindPhaseUpdates`: not for `receiving` or `notified`, serialised per memo, latest state wins, errors logged only.
  The alert carries `category: MEMO_DONE` only (the `MEMO_NEEDS_ROUTE` alert and `notifier.needsRoute` are gone with the park).

- **APNs transport:** node-apn builds the ES256 JWT with `jsonwebtoken` and regenerates it when its `iat` is 3300 s (55 min)
  old, checked per request (Apple: not <20, not >60 min); it retries 408/429/5xx and ExpiredProviderToken 3x. We cap in-flight
  streams at 10 (Bun ignores `peerMaxConcurrentStreams`) and send the first request per environment alone (Apple allows one
  stream until a valid token lands; a status-0 failure re-arms that). `config.port` (443) is passed to `http2.connect` and Bun
  honours it over the URL, so a test server needs `address` and `port` both. Not verified: real Apple hosts and GOAWAY JSON.
  node-apn emits a harmless `MaxListenersExceededWarning` (one `timeout` listener per stream on the session) above 10 streams.

- **Live Activity contract (Swift side):** payload `aps` is `{timestamp, event, "content-state"}` (+ `alert` {title, body, sound} on the final `update` with phase `done`, which is the memo's announcement, and `dismissal-date` now + 15 min on the following `end`, which has no alert). `ContentState` is plain camelCase Codable: `phase` (`processing` | `done` | `failed` on the wire),
  `routeChip?` (the memo's `kind`, capitalised), `headline?` (≤ 60), `hasReply`. `inputName` is never sent: the client keeps it device-side and must declare it
  optional. Alerts carry the kind chip (title, "Iris" without a kind) + headline only (never transcript or reply), `category: MEMO_DONE`, `thread-id: memo`, `mutable-content: 1` and a top-level `memo` id.

- **Telemetry relay** (`POST /v1/telemetry`, TDD §8): the route reads and validates its own body (`parse: "none"`, `TypeCompiler` over
  `TelemetryBatch`) so a bad token is 401 before any byte is read and an oversized body is cut off at 256 KiB (413 `too_large`).
  `compose()` always builds it (a `fakeOtlpExporter` under `IRIS_FAKES`, else `exportOtlp`, a no-op without `OTEL_EXPORTER_OTLP_ENDPOINT`).
  An export that fails, or is refused because `MAX_IN_FLIGHT` (4) posts are already outstanding (same bound as the batch flush, no fetch), is a `telemetry.relay_failed` log line, never an error to the client; the export is registered with `flushOtel`,
  so the shutdown flush waits for it. Resource: `service.namespace=iris`, `service.name` (client), `service.version`, `device.name`, `deployment.environment.name` (prod; dev for a build without a sha);
  `host.name` is the device name on `iris-macos` records (the Mac is a host the telemetry contract names) and absent on `iris-ios`; `host.name=mini` is never on client records. No de-duplication of a resent batch.

