# Hark — voice-first front door to the agent platform

Status: plan, 2026-10-27. Working name "Hark", easy to rename. Nothing is built yet.

## TLDR

You speak into the iPhone, usually from the Lock Screen, sometimes for 40
minutes and with the phone in your pocket. The memo ends up in the right place:
a journal entry, a Hermes request or a prompt into a live herdr tab. The Lock
Screen then shows one sharp line saying what happened, with a button to play
the reply aloud. You rarely open the app. When you do, it shows the history and
the Hermes threads, and you can carry on any of them by voice.

Three decisions shape everything:

- **A singleton backend on the mini (`hark-server`), not Hermes direct.** The
  phone can't reach any of the parts it needs. agent-gateway is loopback-only
  with no auth. Hermes `:8642` is granted to `tag:vps` only and takes a
  host-privileged bearer. The herdr socket is local. There is no push service at
  all. One thin server next to all of them makes both apps dumb clients holding
  one per-device token.
- **Hark keeps the memo record, Hermes keeps the conversation.** This is the
  same split Argo uses (Postgres is the record, Hermes sessions are working
  memory). History must survive a Hermes session reset and must also cover memos
  that never went to Hermes, such as journal entries and herdr prompts.
- **The decision model routes only in Auto mode, and over just three
  destinations.** Hermes already routes well through its skills (capture,
  obsidian, dispatch, herdr). Hark only takes away what Hermes is bad at or what
  shouldn't cost an agent turn: journal entries and "send this to tab X".

## Premise check

- **Not another chat client.** Argo is getting a threaded Hermes chat
  (`argo/docs/HERMES-CHAT-V2.md`). Hark is voice-first: record → result. Its
  thread view is a read-mostly transcript with "reply by voice". It does not
  rebuild a second chat UI.
- **Not a Collie replacement.** Collie stays the phone's full herdr cockpit.
  Hark only *sends into* a tab. It does not drive one.
- **Two routers would be one too many.** If Auto mode routed every memo with
  `decide` and then Hermes re-routed it, confidence would be paid for twice.
  Rule: anything that is neither journal nor herdr goes to Hermes untouched, and
  Hermes's skills decide from there (todo, note, warden work, answer).

## Architecture

```
iPhone app ─┐                                   ┌─> audio-gateway (VPS)  STT Voxtral / TTS
 + widgets  │  HTTPS, tailnet only               │
 + LiveAct  ├─> hark.mini.<domain> ─> hark-server ┼─> agent-gateway :7705  decide / triage
Mac app ────┘   (Caddy door)         (mini, Bun)  ├─> Hermes :8642         sessions + chat/stream
                     ▲                            ├─> herdr socket         snapshot / send_text
                     └──── APNs (alerts + Live    ├─> brain Inbox/         journal (brain-sync lock)
                            Activity updates)     └─> SQLite + audio files
```

- **Network:** `tag:phone → tag:devhost :443` is already granted. A Caddy block
  `hark.test` → `make caddy-tailnet` produces the door. No ACL change.
- **Auth:** a per-device bearer (`HARK_DEVICE_TOKENS`, the same pattern as
  audio-gateway caller tokens), stored in the Keychain of each app. Every
  downstream credential (Hermes bearer, audio key, APNs `.p8`) stays on the mini
  through `secrets-run`.
- **Stack:** Bun + Elysia + `bun:sqlite`, matching argo/image-gateway, run as a
  LaunchAgent `com.jkrumm.hark`. The port `:7730` is a placeholder; register it
  in the Caddyfile.

## Capture (iPhone 15, iOS 26)

**Triggers.** The iPhone 15 has no Action Button, so Hark offers four ways in:

| Trigger | Mechanism | Phone state |
|-|-|-|
| Lock Screen control | `ControlWidgetButton` → `AudioRecordingIntent` | locked |
| Back Tap (double/triple) | Shortcut → Hark App Intent | screen on |
| Siri | `AppShortcutsProvider` phrase | any |
| Control Center / in-app | same intent | any |

**The hard rule from Apple:** an `AudioRecordingIntent` *must* start a Live
Activity when recording begins and keep it alive, or the recording stops. The
Live Activity is therefore the spine of the whole UX, not decoration.

**Live Activity states**, one activity per memo:

`recording 12:34 · iPhone mic [Stop] [Mic]` → `uploading` → `transcribing` →
`routing` → `done: "Journal · 3 min · 'Gedanken zum Factory-Rollout'" [Play]` →
dismissed after ~15 min, or when the next memo starts.

**Recording:**
- **Session:** `.playAndRecord` (Apple's recommendation over `.record`, and
  playback needs no reconfiguration), plus `UIBackgroundModes: audio`.
  `setPrefersNoInterruptionsFromSystemAlerts(true)` keeps ringtones from
  killing a take.
- **Interruptions:** handled through the iOS 26 notifications
  (`didBecomeInactive` / `resumptionRecommendation`).
  `interruptionNotification` is deprecated. A phone call pauses the memo and
  never ends it.
- **Format:** AAC mono 16 kHz at about 32 kbps, roughly 14 MB per hour. Files
  are written in **60 s segments** so a crash or kill loses at most one segment.
  A plain long `.m4a` with no moov atom is unrecoverable.
- **Durable outbox:** segments stay on disk until the server acknowledges them.
  Uploads retry with a `URLSession` background configuration, which covers car
  tunnels and dead zones.

**Input selection.** The car case is the reason this app exists:
- `AVInputPickerInteraction` (iOS 26) for the system picker, plus a compact
  in-app picker on `availableInputs` / `setPreferredInput`. Apple requires
  setting the input after session activation, then reading `currentRoute` back.
- **Per-route memory:** "when *Car BT* is connected, prefer the built-in mic".
  It is applied automatically and shown in the Live Activity.
- **AirPods:** `.bluetoothHighQualityRecording` with `.allowBluetoothHFP` as
  fallback. Apple documents that this is **not supported in the EU**, so expect
  HFP quality in Germany.

## Pipeline (hark-server)

Each memo is a state machine persisted in SQLite. Each step is idempotent, so
a restart resumes it:

1. **ingest:** segments go to `~/.hark/audio/<memo>/`, then a concat when the
   memo is marked complete.
2. **transcribe:** `POST audio-gateway /v1/audio/transcriptions` with model
   Voxtral, the `language` hint and `context_bias` built from repo and tab
   names. The gateway already splits audio past 240 s or 24 MiB, up to about
   2 h.
3. **route:** see below.
4. **act:** journal write, herdr `pane.send_text` plus Enter, or a Hermes
   session message.
5. **summarize:** agw `triage` with the schema
   `{headline ≤60, detail ≤240, spoken ≤2 sentences}` over transcript + action +
   reply.
6. **notify:** an APNs Live Activity update to `done` plus an alert with a
   notification content extension for the rich card. TTS through audio-gateway
   `/v1/audio/speech` is lazy: it runs on [Play], or eagerly when "spoken
   replies" is on.

## Routing

The memo carries a **mode** chosen at capture: Auto (default), Journal, Hermes
or Tab. The last-used tab is a one-tap option in the Live Activity.

Resolution order in Auto mode:

1. **Spoken prefix.** "Journal …", "An Hermes …", "Tab dotfiles …" (German and
   English) are matched deterministically. No model is involved.
2. **`decide`.** The state is the transcript plus the live herdr snapshot (tab
   names, repo, last activity). It answers two questions:
   - `destination: choice[journal, hermes, herdr]`
   - `tab: choice[<live tabs>]`, asked only when relevant
3. **Confidence policy.** At ≥ 0.8 Hark acts. Below that it acts on nothing and
   sends a push with action buttons instead, e.g. `[Hermes] [dotfiles · w1a]
   [Journal]`. Actionable notifications run the choice in the background.

| Destination | Action | Done card |
|-|-|-|
| journal | `brain/Inbox/<date>-<slug>.md`, `tags: [journal]`, under the brain-sync lock | title + word count |
| herdr | `send_text` into the pane | "→ dotfiles · factory-w1a" |
| hermes | `POST /api/sessions` (`source: hark`), then `chat/stream`, collecting the final text | Hermes's answer, condensed |

Hermes replies are where the spoken reply matters. Journal and herdr confirm
silently.

## Apps

- **iOS app.** It contains:
  - a history list (memo, route, state, one-line result) and a memo detail
    view (transcript, audio scrubber, action log, [Play reply]);
  - a Hermes thread view, read-only from the sessions API, with a hold-to-talk
    button that appends a memo to *that* session;
  - Settings: input preferences per route, spoken replies on or off, default
    mode, and the devices.
- **Mac app (later phase).** A `MenuBarExtra(.window)` with a global hotkey (a
  `CGEventTap`; `NSEvent` global monitors reportedly crash on macOS 26) and a
  floating `NSPanel` for the live take. Same server, same history. Sign it with
  a stable Apple Development identity, because ad-hoc signing resets TCC on
  every build.
- **`HarkKit` (SwiftPM).** The API client, models, recorder protocol and
  formatting, shared by the iOS app, the widget/Live Activity extension and the
  Mac app. The Xcode projects are generated by `xcodegen` from `project.yml`,
  so no `.pbxproj` merge fights for agents.
- **Prior art to read:** `FrigadeHQ/yap` (MIT), `opennookorg/betterwispr`
  (Apache-2.0) and `fennelouski/voicekit` (MIT). VoiceInk and FluidVoice are
  GPL-3.0: read them, don't copy. Also clawbar (Swift 6 menu bar, own repo).

## Build and distribution

- **Xcode on the mini.** Today it has Command Line Tools only, which can't build
  iOS. Install Xcode with `xcodes`. Builds, tests and archives then run on the
  mini like every other repo.
- **Paid Apple Developer Program, $99/yr (the open decision).** It unlocks
  TestFlight internal testing, so agents ship builds and the phone auto-updates
  with no cable and no 7-day re-sign. It also unlocks APNs and Live Activity
  push updates, which make results reliable after iOS suspends the app.
  The App Store Connect API key goes to 1Password.
- **Without it:** a free Personal Team. Profiles expire every 7 days, so the app
  must be reinstalled weekly. There is no push, so results only arrive while the
  app still has background time (short memos only). That works for the spike
  and is not viable for daily use.

## Phases

Each phase ends with something usable on the phone. It runs as a `/wave` chain
on the mini. The spikes need your hands and your phone; nothing else should.

| Phase | Scope | Exit check |
|-|-|-|
| **0 — Spikes** (throwaway) | S1: Lock Screen control → `AudioRecordingIntent` → Live Activity → 30 min take with the phone locked and app switching. S2: car + AirPods routing, built-in mic forced while connected to the car. S3: APNs from Bun to the device. | S1 green on the iPhone 15. S2 documents what the car allows. S3 delivers a Live Activity update. |
| **1 — Skeleton** | hark-server ingest/STT/store/Hermes-only. iOS record (control + in-app), outbox, Live Activity states, result push | A memo from the Lock Screen lands in Hermes, and the answer headline shows on the Lock Screen |
| **2 — Routing** | spoken prefixes, `decide`, journal + herdr, low-confidence action buttons, TTS [Play], per-route input memory | A week of daily use, with misroutes logged and counted |
| **3 — History + threads** | history, detail, Hermes thread view, reply-by-voice into a session | Continue a Hermes thread from the phone without Slack |
| **4 — Mac** | menu bar app, hotkey, panel, shared HarkKit | The same memo flow from the MacBook |
| **5 — Polish** | live on-device preview via `SpeechTranscriber` (German support checked at runtime), streaming segment upload, Home Screen widget with the last results | — |

## Risks and unverified

- **S1 can fail.** One unanswered forum report (Feb 2026) shows "Target is not
  foreground" when a Live Activity starts from an intent. If it reproduces, the
  fallback is a control that opens the app and auto-starts recording: one
  animation more, everything else unchanged.
- **Built-in mic plus car audio output** is not documented by Apple. S2 settles
  it on real hardware.
- **Playing TTS from a notification action without opening the app** is
  unverified. The fallback is [Play] on the Live Activity through an
  `AudioPlaybackIntent` (verify it at build time) or a tap into the app.
- **APNs from Bun** (HTTP/2 client, library choice) is to be researched in S3.
- **Voxtral gives no real timestamps.** audio-gateway returns one segment. The
  detail view shows plain text, not a synced transcript.
- **The decision model's confidence calibration** is unknown for this task.
  Phase 2 logs every decision and correction so the 0.8 threshold rests on data.

## Open owner decision

Paid Apple Developer Program: yes or no. Everything past Phase 0 assumes yes.
