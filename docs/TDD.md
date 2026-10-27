# Iris — Technical Design

Status: v1, 2026-10-27. Companion to [`PRD.md`](PRD.md) (what and why). This
file is how it is built, and it wins over any other doc on design. Research
behind the decisions lives in [`research/`](research/). Public repo: no real
hostnames, IPs, tokens or emails anywhere; use `<domain>`-style placeholders.

## TLDR

Iris has three deliverables in one monorepo:

- **`iris-server`** (Bun + Elysia + SQLite) runs on the mini and owns the memo
  record, every credential and every downstream call.
- **Iris for iOS and Iris for macOS** (SwiftUI, iOS/macOS 26+) are thin
  clients built from shared local Swift packages.

**How a memo flows:**
- **Capture:** the phone records 10 s segments and uploads them while I am
  still talking.
- **Processing:** the server concatenates, transcribes (audio-gateway,
  Voxtral), routes (spoken prefix, then agent-gateway `decide`), acts
  (journal, herdr or Hermes), summarizes (`triage`) and notifies (APNs: Live
  Activity update plus a rich alert).
- **Tracing:** one trace per memo, keyed by the memo UUID, spans all three
  runtimes.
- **Verification:** agents build, run, screenshot and test both apps on the
  mini through the CLI only (`xcodebuild`, `simctl`, `devicectl`, `xcresulttool`,
  and the `mobilebuildmcp` CLI for UI automation), wrapped in repo skills. No MCP
  servers. Only the
  hardware-bound checks (Lock Screen control, Bluetooth routing, background
  audio) need my hands.

## Decisions

| # | Decision | Why | Rejected |
|-|-|-|-|
| D1 | A server on the mini, not Hermes direct | The phone can reach neither agw (loopback) nor Hermes `:8642` (VPS-only grant, privileged bearer) nor herdr (socket). Credentials stay on the mini | Apps talking to Hermes/Collie directly |
| D2 | Iris owns the memo record; Hermes owns conversations | History must survive a Hermes reset and cover non-Hermes memos. Mirrors Argo | Hermes sessions as the only store |
| D3 | Routing: prefix → `decide` → ask. Three destinations | Hermes's skills already route todos, notes and work. A second full router would pay twice | `decide` on every intent; an LLM router |
| D4 | 10 s segments, uploaded during the take | A crash loses ≤ 10 s, the upload is done at [Stop], and a mic switch is a segment rollover | One file at [Stop] (loses everything on a crash, slow); shorter (request churn) |
| D5 | `AVAudioEngine` tap → `AVAudioFile` (AAC/m4a) per segment; the server decodes and re-encodes on concat | Continuous buffers plus edit lists make the concatenated decode gapless. `AVAudioRecorder` stop/start drops audio | `ffmpeg -c copy` concat (priming gaps); PCM segments (too large on cellular) |
| D6 | APNs via `@parse/node-apn` on Bun `node:http2`, streams capped at 10 | Maintained and pure JS; `apns2` is broken on Bun (undici). Bun ignores `peerMaxConcurrentStreams`, so cap in-flight streams ourselves | `apns2`, the abandoned `apn`, a Go/Swift sidecar |
| D7 | Hand-rolled OTLP JSON telemetry on all three runtimes; clients relay through the server | The estate convention (no SDK on Bun). The ingestion key stays off the devices. opentelemetry-swift's 2026 status is unverified | opentelemetry-swift, Sentry/Embrace |
| D8 | The memo UUID is the trace id (dashes stripped), minted on the client at record start | Phone, server and usage rows join without an extra column; the trace starts at the press | Server-minted ids |
| D9 | JSON fixtures plus JSON Schema in `contracts/` as the API contract, validated by server tests and decoded by IrisKit tests | Catches client/server drift with no code generator in the build | swift-openapi-generator (heavy build plugin for 2 clients) |
| D10 | XcodeGen (`apple/project.yml`), no `.pbxproj` in git | Agents edit YAML, not pbxproj. Alive (2.46.0, 2026-07) | Tuist (monorepo churn, heavier), a committed pbxproj |
| D11 | Local SPM packages under `apple/Packages/` (Core, Capture, UI, Telemetry) | Testable with `swift test` and per-package Swift Testing; IceCubesApp's proven shape | One app target with folders |
| D12 | Native SwiftUI + Liquid Glass with basalt-ui tokens; Textual for markdown; DSWaveformImage for levels | Apple's glass APIs are the premium path, and third-party glass kits aren't ready. `AttributedString(markdown:)` is inline-only | A component kit; swift-markdown-ui (maintenance mode) |
| D13 | iOS/macOS 26.0 minimum; built with Xcode 27.1 (Swift 6.4), Swift 6 language mode, MainActor default isolation for app targets (SE-0466) | iOS 26 has every capture API we need. Xcode 27 matches the CI `xcode-27` image | iOS 27 minimum (excludes nothing useful) |
| D14 | CI: the server on `ubuntu-latest`, Apple on the `xcode-27` hosted label (free on a public repo) | `macos-26` tops out at Xcode 26.6 and one Xcode major per macOS version; parity with the mini's 27.1 | `macos-26` + Xcode 26.6 (toolchain skew) |
| D15 | Distribution through TestFlight internal testing (paid program, enrolling); a free team plus `devicectl` until then | Agents upload from the mini, devices auto-update | Weekly free-team re-sign |
| D17 | CLI-only agent tooling: Apple's CLIs plus the `mobilebuildmcp` CLI (pinned, via `npx`), wrapped in repo skills and Make targets. No MCP server, global or project | The owner doesn't want MCP wired. The CLI exposes the same tools (`ui-automation snapshot-ui/tap/type-text/screenshot`, `simulator`, `device`). `mcpbridge` also needs the Xcode GUI open with the project | `.mcp.json` with MobileBuildMCP; Xcode `mcpbridge` |
| D16 | A public GitHub repo | No secrets in the tree by construction; free macOS CI | Private + self-hosted (no macOS runner there) |

## 1. System context

```
 iPhone (iOS app · IrisWidgets · IrisNotifications) ─┐
                                                     ├─ HTTPS, tailnet ─> iris.mini.<domain> (Caddy) ─> iris-server :7730
 MacBook (Iris for macOS, menu bar) ─────────────────┘                                              │
          ▲                                                                                         ├─> audio-gateway (VPS)  STT · TTS
          └──────────── APNs (alert · liveactivity) <───────────────────────────────────────────────┤
                                                                                                    ├─> agent-gateway 127.0.0.1:7705  decide · triage
                                                                                                    ├─> Hermes :8642 (mini tailnet IP)  sessions
                                                                                                    ├─> herdr socket  snapshot · send_text
                                                                                                    ├─> ~/SourceRoot/brain/Inbox  (brain-sync lock)
                                                                                                    ├─> ~/.iris/data  (SQLite · audio)
                                                                                                    └─> otel.<domain>  OTLP traces + logs
```

- **Network:** `tag:phone → tag:devhost :443` is already granted, so no ACL
  change is needed. The Caddy block `iris.test` becomes
  `iris.mini.<domain>` via `make caddy-tailnet`.
- **Trust boundary:** the tailnet plus a per-device bearer. Nothing is public.

## 2. Repository layout

```
iris/
  AGENTS.md                 the only agent instruction file (dotfiles/docs/agents-md.md)
  Makefile                  check = check-server + check-contracts + check-apple
  contracts/                schema/*.json (JSON Schema) + fixtures/*.json, one pair per endpoint/event
  server/                   Bun + Elysia + bun:sqlite (§3)
  apple/
    project.yml             XcodeGen: Iris (iOS app), IrisWidgets, IrisNotifications, IrisMac
    Packages/
      IrisCore/             models, API client, SSE, contracts decoding, device auth
      IrisCapture/          audio session, route manager, engine tap, segment writer, outbox
      IrisUI/               Theme (basalt tokens), components, Live Activity views, markdown
      IrisTelemetry/        span/log buffer, relay exporter, MetricKit bridge
    Iris/ IrisWidgets/ IrisNotifications/ IrisMac/   thin targets: composition + target-only code
    Tests/UITests/          XCUITest smoke flows
  scripts/                  launch.sh, mini-deploy.sh, send-memo.ts, device helpers
  launchd/                  *.plist.template
  .claude/skills/           repo skills (§10)
  docs/                     PRD, TDD, research/, spikes/, waves/
```

## 3. iris-server

### Modules

The server is a few deep modules behind ports, in email-gateway's style.
`app.ts` is the only place adapters meet ports.

| Module | Owns | Public interface |
|-|-|-|
| `memo/` | The state machine, `MemoStore` (SQLite), the step runner | `createMemo`, `putSegment`, `complete`, `get`, `list`, `retry`, `events` (an async iterator) |
| `pipeline/` | One file per step; each step is a pure function of (memo, ports) | `steps: Record<Step, StepFn>` |
| `routing/` | Prefix parser, the `decide` call, confidence policy, decision log | `route(transcript, herd, mode) → RouteDecision` |
| `devices/` | Device tokens, APNs and push-to-start tokens, Live Activity tokens | `authenticate`, `register`, `tokensFor` |
| `notify/` | Payload building (alert, Live Activity), APNs transport | `Notifier` port |
| `telemetry/` | `otel.ts`, `otel-format.ts`, `log.ts`, the client relay | `withRootSpan`, `withSpan`, `log`, `relay` |

Ports, each with a production adapter and an in-memory fake:
- `Transcriber`
- `Speaker`
- `Router` (`decide`)
- `Summarizer` (`triage`)
- `Herd`
- `Destination` (journal | herdr | hermes)
- `Notifier`
- `Clock`
- `Ids`

### Memo state machine

```
receiving ──complete──> received ──> transcribed ──> routed ──> acted ──> summarized ──> notified (terminal)
                                          └──> needs_route ──(device answers)──> routed
any step ──error──> failed(step)   ──retry(from)──> <step>
```

- **Idempotent steps:** each step is keyed by `(memo_id, step, attempt)`. On
  boot and on every `complete`, the runner drives each non-terminal memo from
  its last finished step.
- **Timeouts:**

  | Step | Timeout |
  |-|-|
  | STT | 300 s |
  | decide | 30 s |
  | Hermes | 180 s |
  | triage | 30 s |
  | APNs | 10 s |

- **Retries:** two automatic retries with backoff on transient errors (5xx,
  timeout). Anything else goes to `failed`.
- **Retention:** audio is deleted 30 days after `notified`; rows are kept.

### Data model (SQLite, WAL, migrations in `server/src/memo/migrations/`)

| Table | Columns (key ones) |
|-|-|
| `devices` | `id`, `name`, `platform` (ios/macos), `token_hash`, `apns_token`, `apns_env` (sandbox/production), `push_to_start_token`, `last_seen_at` |
| `memos` | `id` (uuid, client-minted), `device_id`, `mode` (auto/journal/hermes/tab), `target_tab`, `thread_id`, `state`, `failed_step`, `error`, `language`, `started_at`, `completed_at`, `segment_count`, `audio_seconds`, `transcript`, `route`, `route_source` (prefix/decide/manual/mode), `destination_ref`, `reply_text`, `summary` (json), `cost_usd` |
| `segments` | `memo_id`, `idx`, `bytes`, `sha256`, `received_at` — PK (`memo_id`, `idx`) |
| `steps` | `memo_id`, `step`, `attempt`, `started_at`, `ended_at`, `status`, `error`, `usage` (json), `cost_usd` |
| `route_decisions` | `memo_id`, `source`, `destination`, `tab`, `confidence`, `probabilities` (json), `corrected_to`, `created_at` |
| `activity_tokens` | `memo_id`, `token`, `updated_at` |
| `threads` | `id` (the Hermes session id), `title`, `created_at`, `last_memo_id` |

### HTTP API (`/v1`, bearer = device token; `/health` is public)

| Method + path | Purpose |
|-|-|
| `POST /v1/devices/register` | `{name, platform, apnsToken?, apnsEnv?, pushToStartToken?}`; upsert by the authenticated device |
| `POST /v1/memos` | `{id, mode, targetTab?, threadId?, startedAt, language?}`, idempotent |
| `PUT /v1/memos/:id/segments/:n` | Raw m4a bytes, idempotent by `n` (same sha → 200, different → 409) |
| `POST /v1/memos/:id/complete` | `{segmentCount}`. A 422 lists the missing indices |
| `PUT /v1/memos/:id/activity-token` | The Live Activity push token for this memo |
| `POST /v1/memos/:id/route` | `{destination, tab?}`, answering `needs_route`; logged as a correction |
| `POST /v1/memos/:id/retry` | `{from: Step}` |
| `GET /v1/memos?cursor&q` | History, paged, transcript search (FTS5) |
| `GET /v1/memos/:id` | Memo + step timeline + decisions + cost |
| `GET /v1/memos/:id/result?wait=<s>` | Long-poll until terminal (≤ 600 s) |
| `GET /v1/memos/:id/audio` | The concatenated audio for the scrubber |
| `GET /v1/memos/:id/speech` | TTS of `summary.spoken` (or `reply_text`), cached as an mp3 |
| `GET /v1/events` | SSE: `memo.updated`, `memo.done` (for the Mac and the foreground iOS app) |
| `GET /v1/herd` | Live herdr tabs `{id, repo, label, agentState, lastActivity}` for the Tab picker |
| `GET /v1/threads`, `GET /v1/threads/:id` | Iris-created Hermes sessions and their transcript |
| `POST /v1/telemetry` | Client span/log batches → re-emitted as OTLP (§8) |

Every request and response body has a schema and a fixture in `contracts/`.
Elysia routes declare TypeBox schemas, and `make check-contracts` asserts that
the exported JSON Schema matches `contracts/schema`.

### Pipeline steps

1. **concat:** `ffmpeg -f concat` over the segments → decode → mono 16 kHz
   AAC. Records `audio_seconds`.
2. **transcribe:** `POST <audio-gateway>/v1/audio/transcriptions`.
   - Fields: `model=voxtral-mini-transcribe-3-0`, `language` (the device hint or
     auto), and `context_bias` (repo names, live tab labels, recent thread
     titles).
   - Header: `x-audio-source: iris`.
   - The gateway handles chunking up to about 2 h. A 413 is terminal.
3. **route:**
   - If the memo's mode is not auto, it wins.
   - Otherwise the prefix parser matches "journal|tagebuch", "an hermes|hermes",
     "tab <name>", case- and diacritic-insensitive, within the first 6 words.
     The prefix is stripped from the transcript.
   - Otherwise call `decide` with state = transcript (first 4k chars) + herd
     summary, and questions: `destination: choice[journal, hermes, herdr]`,
     plus `tab: choice[...]` when there are live tabs.
   - At confidence ≥ 0.8 → `routed`; otherwise `needs_route`.
   - Every outcome is written to `route_decisions`.
4. **act:**

   | Destination | Action |
   |-|-|
   | journal | Write `brain/Inbox/<YYYY-MM-DD>-<slug>.md` (frontmatter `title`, `date`, `tags: [journal, iris]`, `source: iris`, `memo`) under the brain-sync lock (`brain/docs/brain-access.md`), then commit and push following that doc |
   | herdr | `pane.send_text` (the transcript) + `send_keys Enter` on the resolved pane over the herdr socket. Fails if the tab is gone, which leads to `needs_route` |
   | hermes | `POST /api/sessions {id: thread_id ?? new, source: "iris"}` (201/409 = OK) → `POST /api/sessions/:id/chat/stream {message}`. Collect the final assistant text from the SSE, store it as `reply_text`, and upsert `threads` |
5. **summarize:** agw `triage` with the schema
   `{headline (≤60), detail (≤240), spoken (≤2 sentences)}` over the
   destination, transcript excerpt and reply. Journal and herdr skip the model
   and use templates (no spend).
6. **notify:**
   - a Live Activity `update` (priority 5) for each phase change, plus a final
     `end` with the result content state and `dismissal-date` = now + 15 min;
   - one alert (priority 10, `mutable-content: 1`, `category: MEMO_DONE` or
     `MEMO_NEEDS_ROUTE`, `thread-id: memo`, a `memo` id in the custom payload);
   - SSE `memo.done`;
   - a `log` stand-in when APNs is not configured.

### Downstream facts (re-verify when touching an adapter)

| Downstream | Contract | Where it is documented |
|-|-|-|
| audio-gateway | Synchronous multipart; `{text}` (`verbose_json` = one segment, so no timestamps); TTS at `POST /v1/audio/speech`, `response_format` mp3 | `audio-gateway/README.md` |
| agent-gateway | `POST :7705/api/jobs {tool, params}` → id; `GET /api/jobs/:id`; loopback, no auth; results carry `usage`, `model`, `latencyMs` | `agent-gateway/server/routes/jobs.ts`, AGENTS.md |
| Hermes | Bearer from `op://hermes/gateway/api-server-key`; SSE named events | `argo/apps/api/src/lib/hermes-upstream.ts` |
| herdr | Newline-delimited JSON over `~/.config/herdr/herdr.sock`: `session.snapshot`, `pane.send_text`, `pane.send_keys` | collie `HERDR_API.md` |
| APNs | HTTP/2 `api.push.apple.com` / `api.sandbox.push.apple.com`. ES256 provider JWT, refreshed every 20–60 min (we use 50). Live Activity: `apns-push-type: liveactivity`, topic `<bundle>.push-type.liveactivity`, `aps.{timestamp, event, content-state}`. Priority 5 doesn't consume the budget, 10 does | `docs/research/2026-10-27-apns-from-bun.md` |

### Configuration and secrets

`server/src/env.ts` is the only parser of `process.env`. On the mini,
`scripts/launch.sh` runs `secrets-run run --env-file=.env.local.tpl
--env-file=.env.mini.tpl [--env-file=.env.mini.otel.tpl]`.

| Variable | Contents |
|-|-|
| `IRIS_DEVICE_TOKENS` | Device tokens |
| `IRIS_DATA` | The data directory |
| `AUDIO_GATEWAY_URL` | audio-gateway base URL |
| `AGW_URL` | agent-gateway base URL |
| `HERMES_URL`, `HERMES_TOKEN` | Hermes endpoint and bearer |
| `HERDR_SOCKET` | Path to the herdr socket |
| `BRAIN_DIR` | The brain checkout |
| `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` | APNs credentials |
| `OTEL_*` | Telemetry export |

New refs go into `dotfiles-private/headless.refs`.

## 4. iOS app

### Targets

| Target | Contents |
|-|-|
| `Iris` | The app: composition root, scenes, App Intents, `AppShortcutsProvider`, notification delegate |
| `IrisWidgets` | `ControlWidget` (start/stop), the Live Activity (`ActivityConfiguration` with Lock Screen + Dynamic Island) |
| `IrisNotifications` | `UNNotificationContentExtension` hosting SwiftUI (result card, [Play]) |

An App Group, `group.com.jkrumm.iris`, shares the device token (Keychain
access group), recent results and settings.

### Capture engine (`IrisCapture`)

- **`AudioSessionController`:**
  - `.playAndRecord`, mode `.default`, options `.allowBluetoothHFP`,
    `.allowBluetoothA2DP` and `.bluetoothHighQualityRecording` (falls back to
    HFP; not available in the EU);
  - `setPrefersNoInterruptionsFromSystemAlerts(true)`;
  - interruptions handled through the iOS 26 notifications (`didBecomeInactive`,
    `resumptionRecommendation`). The take pauses (a segment boundary) and
    resumes.
- **`RouteManager`:**
  - lists `availableInputs`, applies `setPreferredInput` after activation, and
    reads back `currentRoute`;
  - per-route rules in device-local settings (`[routeFingerprint: preferredPortUID]`),
    applied at start and on route change;
  - publishes `currentInput` for the UI and the Live Activity.
- **`SegmentRecorder`:**
  - an `AVAudioEngine` input tap → `AVAudioConverter` → `AVAudioFile` (AAC,
    16 kHz mono, about 32 kbps);
  - rotates files every 10 s of frames, on a mic switch, and on an
    interruption;
  - each closed file goes to the `Outbox`;
  - a level meter is fed from tap RMS;
  - an engine configuration change restarts the engine and starts a new
    segment.
- **`Outbox`:**
  - a persistent queue in the App Group container, one entry per
    (memo, segment);
  - during the take it uploads over a default `URLSession` (the app is alive
    through background audio);
  - after [Stop], the remainder plus `complete` go through a background
    `URLSession`, followed by the `result?wait=600` long-poll as a background
    download, a backstop to APNs;
  - retries survive relaunches.
- **Memo ids** are minted at start: a UUID v4, which also serves as the trace
  id.

### Start paths

- **The intent:** `StartMemoIntent: AudioRecordingIntent` (+ `LiveActivityIntent`
  semantics) starts the engine and `Activity<MemoAttributes>.request(...)` in
  `perform()`. Apple requires the Live Activity, or the recording stops.
- **Callers:** the `ControlWidget` button calls the intent. So do Siri ("Record
  with Iris") and Control Center.
- **Fallback, accepted by the PRD:** if the system refuses to start a Live
  Activity from the background ("Target is not foreground", reported once), the
  control uses `openAppWhenRun` and the app auto-starts. Spike S1 decides.
- **`StopMemoIntent`, `SwitchInputIntent`, `PlayReplyIntent`:**
  `LiveActivityIntent`s used by the Live Activity buttons. `PlayReplyIntent`
  activates the session and plays `/speech`. Verify that playback starts from
  the background (S3); otherwise it opens the app.

### Live Activity (`MemoAttributes`)

- **Static:** `memoId`, `mode`, `startedAt`.
- **`ContentState`** (well under the 4 KB limit):
  - `phase` (recording/paused/uploading/processing/needsRoute/done/failed);
  - `inputName`;
  - `routeChip`;
  - `headline` (≤ 60 chars; the Lock Screen truncates around 160 pt);
  - `hasReply`.
- **Timer:** `Text(timerInterval:)` with `numericText` transitions.
- **Lifetime:** 8 h, plus 4 h on the Lock Screen, which is plenty for a 2 h
  take.
- **Updates:** local while the app runs; remote via APNs after suspension (the
  push token is registered per memo).

### Notifications

- **Registration:** `registerForRemoteNotifications()` on every launch, with
  the token sent via `devices/register`. The push-to-start token comes from
  `Activity<MemoAttributes>.pushToStartTokenUpdates`.
- **Categories:**
  - `MEMO_DONE`: [Play] [Reply by voice] [Open];
  - `MEMO_NEEDS_ROUTE`: up to 3 route actions from the payload;
  - [Reply by voice] opens the app in recording mode bound to `threadId`
    (foreground required for capture).
- **Content extension:** headline, route chip, the condensed answer (Textual
  markdown), and an inline [Play] using the shared player.

### Screens

| Screen | Content |
|-|-|
| History | Memo rows (route chip · state · headline · relative time), search, pull to refresh, SSE live updates |
| Memo detail | Transcript, audio scrubber, step timeline (durations, errors), route decision with confidence, cost, [Retry from…], [Play] |
| Thread | The Hermes transcript rendered with Textual, with hold-to-talk to append to this thread |
| Record | Full-screen take: timer, level waveform, mic picker (`AVInputPickerInteraction` + own list), mode/tab picker, [Stop] |
| Settings | Route mic rules, default mode, spoken replies, server URL + device token (Keychain), diagnostics (outbox, last errors, trace id copy) |

## 5. macOS app (`IrisMac`)

- **Window and hotkey:** `MenuBarExtra` with `.menuBarExtraStyle(.window)`,
  `LSUIElement`. The global hotkey goes through `KeyboardShortcuts`
  (Carbon-based, no Accessibility prompt) if it holds up on macOS 26, otherwise
  a `CGEventTap`. `NSEvent` global monitors reportedly crash on macOS 26.
- **Panel:** a floating non-activating `NSPanel` for the take, showing the
  timer, level and mic picker.
- **Capture:** the same `IrisCapture` package; Mac input devices come from
  Core Audio, and per-device mic rules are local.
- **Notifications:** live SSE `/v1/events` for status, local notifications
  while it runs, and APNs registration for when it is asleep.
- **Signing:** a stable Apple Development identity. Ad-hoc signing resets TCC
  on every build.

## 6. Shared Swift packages

| Package | Depends on | Tested with |
|-|-|-|
| `IrisCore` | Foundation | Swift Testing: fixture decoding from `contracts/fixtures`, API client against a `URLProtocol` stub, SSE parser |
| `IrisCapture` | IrisCore, AVFAudio | Swift Testing: segment rotation and outbox state machine against a fake engine/clock; real audio only in device spikes |
| `IrisUI` | IrisCore | swift-snapshot-testing (1.19.x, Swift Testing traits) for components and Live Activity views, pinned to one simulator runtime |
| `IrisTelemetry` | IrisCore | Swift Testing: batching, relay payload shape, drop-on-overflow |

Swift settings: Swift 6 language mode and complete strict concurrency; app
targets use MainActor default isolation (SE-0466). The exact build-setting
spelling is verified in the setup wave, because the research couldn't confirm
it.

## 7. UI system

- **Theme:** basalt-ui's color palette, type scale, radius and spacing tokens
  ported into `IrisUI/Theme`. One source file, with a script that regenerates
  it from basalt-ui's token export so the two can't drift.
- **Liquid Glass:**
  - `glassEffect(_:in:)` inside `GlassEffectContainer` for floating controls
    (record button, mic picker, route chips);
  - `.buttonStyle(.glass)`;
  - one transition style app-wide (`matchedGeometry`);
  - Apple warns against many concurrent glass effects, so glass is limited to
    controls and content stays flat.
- **Motion carries state:** a recording pulse, step progress in the timeline,
  `numericText` timers. Nothing decorative.
- **Libraries:** Textual (MIT, the markdown successor to swift-markdown-ui),
  DSWaveformImage (MIT, the live level waveform), SwiftUI-Introspect (MIT) only
  where unavoidable. No glass kits.
- **Process:** an HTML mockup round (history, detail, Record, Live Activity,
  notification card) is reviewed before any screen is built in Swift.
  Snapshots then lock the result.

## 8. Telemetry

- **One trace per memo,** with trace id = the memo UUID without dashes:
  - **iOS:** `capture` root (control press → engine running), then `segment.upload`
    × n, `mic.switch`, `interruption`, `outbox.retry`;
  - **server:** `memo` with a child per step and per downstream call;
  - **iOS again:** `notify.received`, `play`.
- **Server:** `withRootSpan`/`withSpan`/`log` from the copied research-gateway
  files.
  - Resource attributes: `service.name=iris-server`, `host.name=mini`, and
    `deployment.environment`.
  - Metrics as named log events: `memo.completed{route, audio_s, total_ms,
    cost_usd}`, `route.decided{source, confidence, corrected}`, `stt.latency`.
- **Clients:** `IrisTelemetry` buffers spans and logs (in memory plus a file
  for crash survival) and flushes batches to `POST /v1/telemetry` every 10 s,
  on background, and on launch.
  - The server re-emits them as OTLP with `service.name=iris-ios|iris-macos`,
    device name and app version.
  - On iOS, MetricKit crash and hang diagnostics are relayed on the next launch.
- **Propagation:** audio-gateway and agw don't accept `traceparent` (factory
  ADR-006 plans it), so Iris spans carry the memo id as an attribute on every
  downstream call. Once ADR-006 lands, `traceparent` is added.
- **Cost:**
  - STT/TTS spend is recorded by audio-gateway (`raw.caller=iris` via
    `x-audio-source`);
  - `decide`/`triage` spend goes into agw's NDJSON feed for usage-tracker;
  - Iris posts no usage rows (they would double-count). It stores per-step
    `usage`/`cost_usd` for the memo detail.
  - Gap: agw jobs have no `caller` field. Adding one is a small agw change,
    queued in the Routing wave.
- **Later (not R0–R3):** HyperDX alerts (`iris memo-failed ≥ 1/15m`,
  `iris-ios crash`) to Slack + warden, and a `probe_iris` in
  `devhost-health-check.sh`.

## 9. Testing and verification

| Layer | Tool | Runs where | Gate |
|-|-|-|-|
| Server unit/integration | `bun test`, in-memory SQLite, fake ports, `app.handle(new Request())` | mini, CI | `make check-server` |
| Contracts | Server: response ⊨ `contracts/schema`; Swift: decode every fixture | mini, CI | `make check-contracts`, `swift test` |
| Pipeline end to end (fakes) | `scripts/send-memo.ts` against a server booted with fake downstreams | mini, CI | `make e2e` |
| Pipeline smoke (real) | `send-memo.ts --real` against `iris.mini.<domain>` with `fixtures/audio/de-90s.m4a` | mini | `make smoke` (post-deploy) |
| Swift packages | Swift Testing via `swift test` per package | mini, CI | `make check-apple` |
| Views | swift-snapshot-testing on a pinned simulator (iPhone 17, iOS 26.x) | mini, CI (`xcode-27`) | `make snapshots` (record with `RECORD=1`) |
| App flows | XCUITest smoke: launch → history → detail; Record screen with a fake recorder (`-IrisFakeCapture`) | mini, CI | `make uitest` |
| Agent verification | `xcodebuild` build/test, `xcrun simctl` (boot + `bootstatus -b`, install, launch, `io screenshot`, `openurl`, `push` for simulated notifications), and the `mobilebuildmcp` CLI (`ui-automation snapshot-ui` / `tap` / `type-text` / `screenshot`) | mini | `@verifier` / the `ios-verify` skill |
| Physical device | `devicectl device install app`; screenshots via `pymobiledevice3 developer core-device screen-capture screenshot` (devicectl has no screenshot verb) | mini → iPhone on LAN | `device` skill |
| Hardware-only | A checklist in `docs/spikes/device-checklist.md`: Lock Screen control, a 30-min background take, a mic switch iPhone↔AirPods↔car, a phone-call interruption, APNs Live Activity update | my hands | before each R-release |

- **Fakes, not mocks:** every port has a fake used by both unit tests and the
  e2e boot mode (`IRIS_FAKES=1`).
- **Fake capture:** a `FakeCapture` build flag swaps `SegmentRecorder` for a
  file-backed generator, so UI tests and screenshots run without a microphone.
- **Snapshot hygiene:** a reference must come from the same simulator
  runtime. CI and the mini pin the same device and OS (Xcode 27.1 image).

## 10. Agent tooling in the repo

- **No MCP servers** (D17). The `ios-verify` and `device` skills call the CLIs
  directly. UI automation goes through
  `scripts/mbm` → `npx -y mobilebuildmcp@<pinned> <workflow> <tool>`, with
  `--style minimal` and its Sentry telemetry disabled through the environment
  (verify the variable name at setup).
- **Swift layer, repo-local** (Iris is the only Swift project; other apps will
  use Tauri / React Native):
  - `.claude/rules/swift.md`;
  - vendored MIT skills `swiftui-pro`, `swift-concurrency-pro`,
    `swift-testing-pro` and `swiftdata-pro` (from `twostraws/*`, pinned in
    `.claude/skills/VENDORED.md`);
  - `.claude/skills/apple-dev` (toolchain + recipes).

  Only the machine toolchain (XcodeGen, `xcodes`, `pymobiledevice3`) lands in
  dotfiles.
- **Iris rules:** `.claude/rules/apple.md` and `server.md` hold the Iris
  invariants, each pointing at its TDD section.
- **Own skills:**

  | Skill | Covers |
  |-|-|
  | `iris-server` | Ports and adapters rules, adding a step/adapter, contracts workflow, running e2e |
  | `ios-verify` | Generate the project, boot the pinned simulator, build-run, screenshot, snapshot record/compare, UI test; where artifacts land (`.artifacts/`, gitignored) |
  | `device` | Install to the paired iPhone, device screenshot, log stream, the hardware checklist |
  | `memo-debug` | Take a memo id → `GET /v1/memos/:id`, then the HyperDX trace via `/otel`, then retry |
  | `apple-capture-notes` | The verified iOS facts (`AudioRecordingIntent` + Live Activity rule, session options, iOS 26 interruption API, EU Bluetooth caveat, APNs headers), so workers don't re-research |

## 11. Build, CI, distribution

- **Local (mini):** Xcode 27.1 (via `xcodes`, at `~/.local/bin`). `make
  generate` runs `xcodegen` with `apple/project.yml`. `make check` covers
  server + contracts + Apple: format/lint, `swift test`, an `xcodebuild build`
  of all schemes for the simulator, and snapshots.
- **Swift lint/format:** `swift format lint --strict` with a checked-in
  `.swift-format` (toolchain-bundled; verify in the setup wave), plus SwiftLint
  only if it is needed later.
- **CI (`.github/workflows/`):**
  - `server.yml` on `ubuntu-latest`: check-server, check-contracts, e2e with
    fakes;
  - `apple.yml` on `xcode-27`: generate, `swift test`, build, snapshots, UI
    smoke. It is a preview image, so on queueing trouble switch to `macos-26`
    with Xcode 26.6 and no iOS 27-only APIs.
- **Server deploy:**
  - the research-gateway pattern: deploy clone `~/.iris/app`, data in
    `~/.iris/data`;
  - `com.jkrumm.iris` (KeepAlive) and `com.jkrumm.iris-deploy` (a 120 s poller,
    CI-green and idle gated);
  - logs in `~/Library/Logs/iris*.log`;
  - registered in `dotfiles/docs/architecture.md`.
- **App distribution:**
  - TestFlight internal: `xcodebuild archive` → `-exportArchive` →
    upload with an App Store Connect API key from 1Password (the upload command
    is verified when enrollment completes);
  - builds come from the mini via `make testflight`, and devices auto-update.
  - Until enrollment: a free team, then `devicectl` install over Wi-Fi after
    one cabled pairing plus Developer Mode.
- **Bundle ids:** `com.jkrumm.iris`, `.widgets`, `.notifications`,
  `com.jkrumm.iris.mac`.

## 12. Security

- **Repo:** public, so a pre-commit hook and CI grep reject IPs, `*.ts.net`,
  real domains and token shapes.
- **Device tokens:** 32-byte random, stored as SHA-256 on the server and in the
  Keychain (App Group access group) on the device. Rotation via 1Password +
  `IRIS_DEVICE_TOKENS`.
- **Other credentials** (APNs key, Hermes bearer) live only in `secrets-run` on
  the mini.
- **Exposure:** the server binds loopback and Caddy is the only door, on the
  tailnet. There is no public exposure.
- **Content:** transcripts and audio never leave the mini except to
  audio-gateway (STT/TTS) and the agw models. APNs payloads carry headlines
  only, never full transcripts.

## 13. Risks and unverified

| Risk | Plan |
|-|-|
| A Live Activity start from a control intent may need the foreground (one forum report) | S1; the fallback is `openAppWhenRun` + auto-start, accepted by the PRD |
| Built-in mic while connected to the car's Bluetooth is undocumented | S2 on hardware |
| TTS playback from a Live Activity intent while the app is suspended | S3; fall back to opening the app |
| Bun `node:http2` over-dispatch to APNs | Cap in-flight streams (D6); Bun 1.3.14's HTTP/2 `fetch` as a fallback |
| `xcode-27` is a preview CI image | Fall back to `macos-26` (D14) |
| Exact Swift build-setting spellings (default isolation) | Verified in the setup wave against Xcode 27.1 |
| `decide` confidence calibration | Logged decisions and corrections; threshold tuned after 100 memos |
| Voxtral has no timestamps | Plain transcript in R1–R3; revisit if a synced transcript matters |
