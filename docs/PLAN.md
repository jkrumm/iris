# Iris — voice channel into the agent platform

Status: plan v2, 2026-10-27. Nothing is built yet.

## TLDR

Iris is my communication endpoint into the agent estate. I speak into the
iPhone, usually from a Lock Screen control, for anything from ten seconds to
forty minutes. While I do, I can switch apps or lock the phone, and I can change
the microphone mid-take. The memo lands where it belongs: a journal entry, a
Hermes request or a prompt into a live herdr tab. A Live Activity and a native
notification then say in one line what happened, and a Play button reads the
reply aloud. The app itself is for history, Hermes threads and settings. The
same flow comes to the MacBook as a menu-bar app. In the long run Iris can
replace Slack as the place agents reach me.

**Three deliverables, one system:**

| Deliverable | Runtime | Job |
|-|-|-|
| `iris-server` | Bun on the mini, LaunchAgent | Owns the memo record, every credential and every downstream call |
| Iris for iOS | SwiftUI, iOS 26+ | Capture, Live Activity, notifications, history |
| Iris for macOS | SwiftUI menu-bar app | Capture by hotkey, the same history, local notifications |

## Name

**Iris** is the messenger of the gods and Hermes's counterpart: the channel I
speak through, with Hermes as one of the parties on the other end. It is short
and Siri-friendly ("Record with Iris"). Alternatives considered:

- **Uplink:** accurate, but reads as networking.
- **Herald:** close to Hermes, but three syllables.
- **Hark:** the working name; it says listening and nothing about the channel.

## System design

```
 iPhone app ──┐  HTTPS (tailnet)           ┌─> audio-gateway (VPS)    STT Voxtral · TTS
 + Control    │                            ├─> agent-gateway :7705    decide · triage
 + LiveAct    ├─> iris.mini.<domain> ─────>│   iris-server            
 Mac app ─────┘   Caddy door         (mini)├─> Hermes :8642           sessions · chat/stream
      ▲                                    ├─> herdr socket           snapshot · send_text
      │ SSE /v1/events, result long-poll   ├─> brain Inbox/           journal (brain-sync lock)
      └──── ntfy (self-hosted, upstream    ├─> SQLite + ~/.iris/data/audio
             ntfy.sh poll-relay) <─────────┘─> otel.<domain>          traces + logs (+ client telemetry relay)
```

**Why a server on the mini:**
- **Reachability:** the phone can't reach agent-gateway (loopback, no auth),
  Hermes `:8642` (granted to the VPS only, behind a host-privileged bearer), or
  the herdr socket (local). One server sitting next to all of them fixes that.
- **Credentials:** every credential stays on the mini. Clients hold a single
  per-device bearer.
- **Native capabilities:** the server can use the herdr socket and the brain
  checkout directly, and can later run an OpenCode flow, which a phone never
  could.

**Iris owns the memo record, Hermes owns the conversation.** This is the same
split as Argo's (Postgres is the record, Hermes sessions are working memory).
History survives a Hermes session reset and also covers memos that never
touched Hermes.

### iris-server modules

The server is a few deep modules behind ports (`rules/code-style.md`), shaped
like email-gateway (`src/providers/port.ts`): dependencies are injected, tests
use in-memory SQLite and fake ports, and there is no `mock.module`.

```
server/src/
  app.ts              composition root: wires adapters into ports, nothing else
  memo/               the domain: Memo state machine, MemoStore port, idempotent step runner
  pipeline/           ingest → transcribe → route → act → summarize → notify (one file per step)
  ports/              Transcriber · Router · Destination · Summarizer · Speaker · Notifier · Herd · Clock
  adapters/
    audio-gateway.ts  Transcriber + Speaker (x-audio-source: iris)
    agw.ts            Router (decide) + Summarizer (triage) via POST :7705/api/jobs
    hermes.ts         Destination "hermes" (sessions API)
    herdr.ts          Herd (snapshot) + Destination "herdr" (send_text)
    brain.ts          Destination "journal" (Inbox write under the brain-sync lock)
    ntfy.ts           Notifier (now) · apns.ts later, behind the same port
    sqlite.ts         MemoStore
  http/               devices · memos · segments · events (SSE) · result long-poll · tts · telemetry relay
  telemetry/          otel.ts + log.ts, copied from research-gateway (the convention: no SDK)
```

**Swap points are explicit.** `Router` starts as `decide` and can later be an
OpenCode flow. `Notifier` starts as ntfy and becomes APNs once there is a paid
account. `Transcriber` stays on audio-gateway, with an on-device fallback being
a client concern. Each swap means one new adapter plus one line in `app.ts`.

**The memo state machine** is persisted in SQLite:

`receiving → received → transcribed → routed | needs_route → acted → summarized → notified`

`failed(step, error)` is a side state. Every step is idempotent and keyed by the
memo id, so a restart re-runs the last incomplete step. A failed memo can be
re-driven from the app ("retry from transcribe"), and the audio is kept until
the memo reaches `notified` + 30 days.

## Capture (iPhone 15)

**Triggers:** the Lock Screen control replaces the flashlight or camera slot.
If iOS insists on foregrounding the app to start a recording, that is
acceptable, as long as the take survives going back to the Lock Screen or
another app. Siri via `AppShortcutsProvider` and the Control Center control
come for free. Back Tap is dropped (it was buggy).

**Recording rules:**
- **Live Activity:** `AudioRecordingIntent` + Live Activity. Apple requires the
  Live Activity, or the recording stops. The Live Activity is the spine of the
  capture UX:
  `● 12:34 · iPhone-Mikrofon [Mic ▾] [Stop]` → `uploading` → `processing` →
  `done: Journal · 3 min · "Gedanken zum Factory-Rollout" [Play]`.
- **Session:** `.playAndRecord` + `UIBackgroundModes: audio`, and
  `setPrefersNoInterruptionsFromSystemAlerts(true)`. Interruptions use the
  iOS 26 notifications (`didBecomeInactive` / `resumptionRecommendation`). A
  phone call pauses the take and never ends it.
- **Segmented recording, the core mechanism:** AAC mono 16 kHz at about
  32 kbps, in 60 s files.
  - **Crash safety:** a crash costs at most one segment.
  - **Background upload:** segments upload through a background `URLSession`
    while the take is still running.
  - **Mic switching:** a mic switch is a segment rollover (close, reconfigure
    the route, open the next segment) rather than a live route change inside one
    file.
- **Mic switching (must have):**
  - an in-app picker on `availableInputs` / `setPreferredInput`, with the route
    read back from `currentRoute`;
  - `AVInputPickerInteraction` as the system sheet;
  - the current mic always visible in the Live Activity, with [Mic ▾] cycling
    through the available inputs through an intent;
  - **per-route preferences** ("Car BT connected → built-in mic"), applied at
    start. The Mac app keeps the same per-device map, synced through the server
    (`/v1/devices/:id/prefs`).
  - AirPods use HFP: Apple doesn't support `.bluetoothHighQualityRecording` in
    the EU.

## Results and notifications without a paid account

A free Personal Team **cannot use APNs** (Xcode: "Personal development teams do
not support the Push Notifications capability"). So there is no remote Live
Activity update and no remote push. Three channels cover the gap, in order:

1. **Result long-poll as a background download.** After the last segment, the
   app enqueues `GET /v1/memos/:id/result?wait=600` on a background `URLSession`.
   The server answers once the memo reaches `notified`. iOS wakes or relaunches
   the app for the completion (documented behaviour). The app then updates the
   Live Activity locally and posts a **local notification**. Local notifications
   need no entitlement and can carry the TTS mp3 as an attachment, so
   long-pressing plays the reply without opening the app (verify in S3).
2. **ntfy for everything not tied to a memo**, such as a Hermes follow-up, an
   agent asking a question or a failed memo. Self-hosted on the mini with
   `upstream-base-url: https://ntfy.sh`. Only a message id and a topic hash leave
   the mini; the body is fetched from my own server. A tap deep-links via
   `iris://memo/<id>`. The banner comes from the ntfy app, not Iris. That is
   accepted until APNs.
3. **The Mac app holds `/v1/events` (SSE) open permanently** and posts native
   local notifications, so the Mac gets full rich notifications today.

When the paid program arrives: add `adapters/apns.ts` behind `Notifier`, push
Live Activity updates and rich remote notifications, and keep ntfy as a
fallback or drop it. Nothing upstream changes.

The "replace Slack" step is Phase 6 and depends on APNs. It ties in with the
factory decision on push (`dotfiles/docs/factory/tdd/13-decisions.md`: Argo web
push, ntfy fallback). Iris would become a third candidate surface for agent
notifications. Raise it there when Phase 3 is live, not before.

## Routing

The memo carries a mode chosen at capture: **Auto** (default), Journal, Hermes
or Tab.

In Auto mode, rules are tried in order:

1. **Spoken prefix:** "Journal …", "An Hermes …", "Tab dotfiles …", matched
   deterministically.
2. **`decide`** over the transcript and the live herdr snapshot.
   `destination: choice[journal, hermes, herdr]`, plus
   `tab: choice[<live tabs>]` when relevant.
3. **Confidence:** at ≥ 0.8, act. Otherwise the memo goes to `needs_route` and
   the notification offers `[Hermes] [dotfiles · w1a] [Journal]`.

| Destination | Action | Done line |
|-|-|-|
| journal | `brain/Inbox/<date>-<slug>.md`, `tags: [journal]` | title + word count |
| herdr | `send_text` + Enter into the pane | "→ dotfiles · factory-w1a" |
| hermes | `POST /api/sessions` (`source: iris`) → `chat/stream`, final text collected | Hermes's answer, condensed |

Every other intent (todo, note, warden work) goes to Hermes untouched. Its
skills already route those, and a second router would pay for confidence twice.
Every `decide` call and every manual correction is stored, so the threshold and
any later OpenCode router get judged on data.

## Apps

- **IrisKit (SwiftPM, shared):**
  - `API`: a typed client, SSE, and the background session identifiers.
  - `Models`: Memo, Route, Device, Prefs.
  - `Recording`: a `Recorder` protocol, the segmenter and the route
    preferences.
  - `Telemetry`: see below.
  - `UI`: shared SwiftUI components.
- **iOS:** the app target plus one extension target, `IrisWidgets`, holding
  both the control and the Live Activity. That makes 2 App IDs, well inside the
  free limit of 10 per 7 days.
  - No dependency on App Groups. Free-team support is contested, so the state
    the widget needs travels through ActivityKit content state and intent
    parameters.
  - Screens: history (memo · route · state · one line), memo detail
    (transcript, audio scrubber, step timeline, cost, [Retry], [Play]), the
    Hermes thread view (read-only, with hold-to-talk to append into that
    session), and settings (mics per route, spoken replies, default mode).
- **macOS:**
  - `MenuBarExtra(.window)` with a global hotkey via `CGEventTap`. `NSEvent`
    global monitors reportedly crash on macOS 26.
  - A floating `NSPanel` for the live take, showing the mic picker and the
    level meter.
  - It is signed with a stable Apple Development identity, because ad-hoc
    signing resets TCC on every build.
- **Project generation:** `xcodegen` from `apple/project.yml` (no `.pbxproj` in
  git). Use the latest Swift 6 toolchain with strict concurrency.
- **Lint:** `swift format lint --strict`, which ships with the toolchain and
  adds no dependency.
- **Tests:** Swift Testing for IrisKit.
- **Prior art (license-safe):** `FrigadeHQ/yap` (MIT),
  `opennookorg/betterwispr` (Apache-2.0), `fennelouski/voicekit` (MIT). The
  Hermes Desktop app, Hermex for iOS, VoiceInk and FluidVoice (GPL-3.0) are for
  reading only.

## Telemetry, debuggability, cost

Iris follows the estate conventions and has one trace per memo across three
runtimes.

- **The memo id is the trace id.** It is a UUID with the dashes stripped, the
  research-gateway convention, so phone, server and usage rows join without an
  extra column. The client creates the id at recording start, so the trace
  begins on the phone.
- **Server:** `withRootSpan("memo")` per memo, with one child span per pipeline
  step and per downstream call. `service.name=iris-server` and `host.name=mini`.
  The export goes to `otel.<domain>` through the optional `.env.mini.otel.tpl`
  overlay, and `/health` reports `degraded:["otel"]` without it. Logs go to
  `log(event, fields)`, which writes a JSON line plus an OTLP log stamped with
  the trace id.
  - **Metrics as named log events:** `memo.completed{route,duration_s,audio_s,cost_usd}`,
    `route.decided{confidence,corrected}` and `stt.latency`.
- **Clients:**
  - IrisKit `Telemetry` buffers spans and logs (recording, segment upload, mic
    switch, intent start, background wake, crash marker) and posts batches to
    `iris-server /v1/telemetry`. The server re-emits them as OTLP with
    `service.name=iris-ios|iris-macos`, so the ingestion key stays off the
    devices.
  - This is the same hand-rolled pattern as the server, not opentelemetry-swift.
    Its 2026 status is unverified and not worth a dependency for one user.
  - On iOS, `MetricKit` diagnostics (crashes, hangs) are forwarded on the next
    launch.
- **Propagation:** audio-gateway and agent-gateway don't accept `traceparent`
  (factory ADR-006 plans it). Until then, Iris tags its own downstream spans
  with the memo id and sends `x-audio-source: iris`, and agw jobs carry the memo
  id in their params.
- **Cost:** STT/TTS spend is already recorded by audio-gateway (Argo usage rows,
  `raw.caller=iris`). `decide`/`triage` spend goes to agent-gateway's NDJSON
  feed into usage-tracker. **Iris posts no usage rows of its own** (that would
  double-count). It stores the per-step `usage` and `cost` returned on each memo
  for the detail view and the `memo.completed` event.
  - **Gap:** agent-gateway jobs have no caller field, so Iris's agw spend isn't
    attributable in usage-tracker. Add `caller` to `POST /api/jobs`, a small agw
    change, in Phase 2.
- **Alerts:** HyperDX alerts in `vps/observability/alerts/`: `iris memo-failed
  ≥1/15m`, `iris needs_route backlog`, `iris-ios crash`. Both channels go to
  Slack `#alerts` and warden ingest. Warden routes `iris …` to this repo via
  `triage-policy.json`.
- **Health:**
  - a `probe_iris` row in `devhost-health-check.sh`, which feeds the existing
    "MacMini Dev Host" Kuma push;
  - `/health` checks SQLite, the audio-gateway, agw, Hermes and herdr
    reachability, the ntfy status, and the oldest non-terminal memo age.

## Repo and lifecycle (estate conventions)

- **Layout:** `server/`, `apple/`, `launchd/`, `scripts/`, `docs/`. AGENTS.md is
  the only instruction file and has the required sections (Validate, Deploy,
  Verify & Monitor, Gotchas).
- **Make targets:** `check` = `check-server` (oxlint, oxfmt, `tsc --noEmit`,
  `bun test`) plus `check-apple` (`swift format lint`, `swift test` IrisKit,
  `xcodebuild build` for both apps). `deploy`, `verify` and `logs` follow the
  research-gateway pattern.
- **Service:** the research-gateway pattern.
  - The deploy clone is `~/.iris/app` and data lives in `~/.iris/data`.
  - `scripts/launch.sh` runs `secrets-run run --env-file=…`.
  - LaunchAgents: `com.jkrumm.iris` (KeepAlive) and `com.jkrumm.iris-deploy`
    (a 120 s poller, CI-green + idle gate). Both are registered in
    `dotfiles/docs/architecture.md`.
  - The door is `iris.test` in the Caddyfile, then `make caddy-tailnet`. The
    port `:7730` is a placeholder.
- **ntfy:** `com.jkrumm.ntfy` on the mini, loopback, behind its own Caddy door,
  with upstream `ntfy.sh`.
- **CI:** a private repo, `runs-on: [self-hosted, vps]`, server checks only (the
  VPS is Linux). Apple builds run in `make check` on the mini. Direct-to-master,
  not PR-required.
- **Secrets:** new refs (device tokens, ntfy topic token, the Hermes bearer
  reuse) go into `dotfiles-private/headless.refs`, then `make secrets-seed`.

## Build and distribution (free Personal Team)

- **Xcode 27.1 on the mini** via `xcodes`, installed at `~/.local/bin`; the brew
  build fails to link on this toolchain. Then `xcodebuild -license accept` and
  `-runFirstLaunch`.
- **One-time owner steps** (none of them has a CLI path):
  1. Run `xcodes install`, which needs an Apple ID + 2FA.
  2. Add the Apple ID in Xcode Settings → Accounts on the mini, over Screen
     Sharing.
  3. Cable the iPhone to the mini once: Trust, enable Developer Mode, then
     *Connect via Network*.
- **Weekly re-sign is automated:** a `com.jkrumm.iris-resign` LaunchAgent runs
  `xcodebuild -allowProvisioningUpdates archive` → `devicectl device install
  app` over Wi-Fi, starting 36 h before the profile expires, with retries, while
  the phone is on the home LAN. The keychain needs
  `security set-key-partition-list` once, or headless signing hangs on a GUI
  prompt.
- **Mac app:** built and installed on the MacBook from the mini's archive
  (`rsync` + `open`), signed with the same free-team identity.
- **The paid-program trigger** is any of these: ntfy banners feel second-class,
  the weekly re-sign flakes, or Phase 6 (replace Slack) starts.

## Phases

Each phase ends with something I use on the phone. Phases run as a `/wave`
chain on the mini, and only the spikes need my hands.

| Phase | Scope | Exit check |
|-|-|-|
| **0 — Setup + spikes** | Xcode, signing, phone pairing, re-sign agent. S1: Lock Screen control → recording → Live Activity → 30 min take while switching apps and locking. S2: a mid-take mic switch (iPhone ↔ AirPods ↔ car), and forcing the built-in mic while connected to the car. S3: a background-download long-poll wakes the app after 2 min and posts a local notification with an audio attachment | S1–S3 green on the iPhone 15, findings in `docs/spikes/` |
| **1 — Skeleton** | iris-server (ingest, STT, store, Hermes-only, telemetry, health, deploy), iOS capture + outbox + Live Activity + result notification | A Lock Screen memo lands in Hermes, and its answer shows on the Lock Screen. The trace is visible end to end in HyperDX |
| **2 — Routing** | prefixes, `decide`, journal + herdr, `needs_route` actions, TTS [Play], per-route mic prefs, ntfy, agw `caller` | A week of daily use, with misroutes counted on the `route.decided` events |
| **3 — History + threads** | history, memo detail with timeline and cost, retry, the Hermes thread view, reply-by-voice | I continue a Hermes thread from the phone without Slack |
| **4 — Mac** | menu-bar app, hotkey, panel, SSE notifications, shared prefs | The same flow from the MacBook |
| **5 — Polish** | on-device live preview (`SpeechTranscriber`, German checked at runtime), Home Screen widget, spoken-replies mode | — |
| **6 — Agent inbox** (needs the paid program) | APNs adapter, remote Live Activity updates, Hermes/warden/factory messages as rich notifications with reply-by-voice | Slack `#agents` is no longer needed |

## Risks and open questions

- **S1:** one forum report says a Live Activity started from an intent fails
  with "Target is not foreground". The fallback is accepted: the control opens
  the app and auto-starts the take.
- **The background-download wake (S3)** is documented but subject to a rate
  limiter that grows with every background relaunch. If it is unreliable, ntfy
  carries memo results too.
- **The built-in mic while connected to the car** is not documented by Apple.
  S2 settles it on hardware.
- **App Groups on a free team** are contested, so the design doesn't use them.
- **Voxtral returns no real timestamps,** so the detail view shows plain text.
- **The `decide` confidence calibration** is unknown, and Phase 2 measures it.
