# Iris — Product Requirements

Status: v1, 2026-10-27. Owner: Johannes Krumm (the only user). Companion:
[`TDD.md`](TDD.md) holds how it is built.

## TLDR

Iris is my voice channel into the agent estate. I press the Lock Screen control,
talk for anywhere from ten seconds to forty minutes, and the memo lands where it
belongs: a journal entry in the brain, a prompt into a running herdr tab, or a
Hermes request. One sharp line on the Lock Screen then tells me what happened,
and a button plays the answer. I rarely open the app. When I do, it shows the
history and the Hermes threads, and I can continue any of them by voice. The
MacBook gets the same flow from the menu bar. Later, Iris becomes where agents
reach me, replacing Slack `#agents`.

## Problem

The tools I use today each fail differently:

| Today | Fails because |
|-|-|
| iOS keyboard dictation | Short-lived, dies when I switch apps, no routing |
| Slack voice memo in `#inbox` | Slow to start, Slack is the wrong home, Hermes answers aloud in public |
| Hermes Desktop | Clunky, Mac only, 120 s recording cap |
| Hermes on mobile | Doesn't exist in a usable form |
| Any recorder in the car | Records the car's poor microphone; switching inputs is buried in iOS |

There is no single place where a thought becomes an action and I can see what
the action was.

## Principles

- **Capture first.** Starting a memo takes one press and works from the Lock
  Screen. Audio is never lost: at most 10 s on a crash, and nothing when there
  is no network.
- **Never open the app to finish a flow.** The Live Activity and the
  notifications carry status, result, actions and playback.
- **Silent by default.** The result is text. Audio plays only when I ask for it
  or when spoken replies are on. In public, nothing talks.
- **Sharp, not chatty.** A result is one line plus an optional short detail.
  No paragraphs on the Lock Screen.
- **Visible and debuggable.** Every memo shows its steps, timing, cost and any
  error, and can be retried from any step.
- **Mine.** It is built for one user, German and English, on my estate. No
  onboarding, accounts or multi-tenancy.

## Use cases

| ID | Situation | Flow |
|-|-|-|
| U1 | Walking, a thought for the journal | Lock Screen control → "Journal, …" → lock the phone → done card: "Journal · 2 min · <title>" |
| U2 | In the car, an instruction for a running agent | Control → the mic is automatically the iPhone's, not the car's → "Tab dotfiles, …" → "→ dotfiles · factory-w1a" |
| U3 | A question for Hermes | Control → talk → the done card shows the condensed answer → [Play] reads it aloud |
| U4 | A 40-minute brain dump while switching apps | The take survives app switches, the Lock Screen and a phone call (pause and resume); segments upload while I talk |
| U5 | Continue a Hermes thread | Iris → thread → hold-to-talk → the reply appears in place, plus a notification if I left |
| U6 | At the MacBook | Hotkey → floating panel → talk → native notification |
| U7 (later) | An agent needs me | A rich notification with the question → [Reply by voice] → the answer goes back to that agent |

## Requirements

**Capture (iOS)**
- **R-CAP-1:** Start from a Lock Screen control in the system slots; Control
  Center and Siri ("Record with Iris") also start it. Briefly foregrounding the
  app at start is acceptable.
- **R-CAP-2:** The recording continues while the phone is locked, in other apps
  and during calls (paused, then resumed). There is no duration cap below 2 h.
- **R-CAP-3:** The mic can be switched mid-take from the Live Activity and from
  the app. The current input is always visible.
- **R-CAP-4:** Per-route mic preferences ("car → built-in mic"), local to each
  device, applied at start.
- **R-CAP-5:** Audio is persisted in 10 s segments that upload while recording.
  A crash loses at most one segment, and an offline take uploads later on its
  own.
- **R-CAP-6:** The mode is chosen at capture: Auto (default), Journal, Hermes,
  or a specific tab (last-used tab one tap away).

**Results**
- **R-RES-1:** The Live Activity progresses recording → uploading → processing →
  done, with a result line, and updates remotely after the app is suspended.
- **R-RES-2:** A rich notification per memo shows the headline, the route chip
  and the condensed answer, with the actions [Play] [Reply by voice] [Open].
- **R-RES-3:** [Play] speaks the reply (TTS) without opening the app.
  Spoken-replies mode plays automatically.
- **R-RES-4:** A memo that can't be routed confidently asks through
  notification actions and acts on nothing until I answer.

**Routing**
- **R-RTE-1:** Spoken prefixes ("Journal …", "An Hermes …", "Tab <name> …")
  always win.
- **R-RTE-2:** Otherwise the decision model chooses between journal, Hermes and
  a herdr tab using the live tab list. Low confidence leads to R-RES-4.
- **R-RTE-3:** Every intent that is neither journal nor herdr goes to Hermes
  unchanged.
- **R-RTE-4:** Every decision and every manual correction is recorded for
  tuning.

**History and threads**
- **R-HIS-1:** History lists each memo with route, state, one line and time,
  newest first, and is searchable by transcript.
- **R-HIS-2:** Memo detail shows the transcript, the audio scrubber, a step
  timeline with durations, cost, errors, [Retry from step] and [Play].
- **R-HIS-3:** The Hermes thread view shows the session transcript, rendered as
  markdown, with hold-to-talk appending to that session.

**Mac**
- **R-MAC-1:** A menu-bar app with a global hotkey and a floating panel showing
  the timer, level meter and mic picker.
- **R-MAC-2:** The same modes, history and notifications as iOS. Mic preferences
  are its own.

**Operability**
- **R-OPS-1:** One trace per memo, from the phone through the server to every
  downstream call, viewable in HyperDX.
- **R-OPS-2:** The cost per memo (STT, routing, summary, TTS) is visible in the
  memo detail and attributed to Iris in the estate's usage data.
- **R-OPS-3:** The app can be built, run, screenshotted and tested by agents on
  the mini without me, except for one-time device pairing.

## Non-functional

| Concern | Target |
|-|-|
| Start latency | Control press → recording in < 1.5 s |
| Audio loss | ≤ 10 s on a crash, 0 when offline (an outbox) |
| Result latency | A 2-min journal memo: done card < 20 s after [Stop]; Hermes: STT + Hermes time + < 5 s |
| Privacy | Tailnet only; audio kept 30 days after done; transcripts kept indefinitely on the mini |
| Cost | Visible per memo; no hidden model calls |
| Availability | Capture works with the server down (queued); results need the mini |

## Non-goals

- No App Store release, no other users, no accounts.
- No full chat client: Argo's Hermes chat stays the rich web surface.
- No replacement for Collie: Iris sends into a tab but does not drive one.
- No on-device-only transcription as the source of truth (live preview only,
  later).
- Android, Watch and CarPlay are out of scope for now.

## Release plan

| Release | Contains | I can |
|-|-|-|
| R0 — Server | iris-server live on the mini, end to end via a test script | — |
| R1 — Capture | iOS capture + Live Activity + Hermes route + result notification | Use it daily for Hermes |
| R2 — Routing | journal + herdr + the decision model + [Play] + mic preferences | Use it for everything I speak |
| R3 — History | history, detail, retry, Hermes threads, reply by voice | Leave Slack voice memos |
| R4 — Mac | menu-bar app | Use it at the desk |
| R5 — Polish | live on-device preview, widgets, spoken-replies mode | — |
| R6 — Agent inbox | agents reach me through Iris, reply by voice | Mute Slack `#agents` |

## Success

- **Adoption:** after R2, Iris carries ≥ 90 % of my spoken input (Slack voice
  memos go to zero).
- **Routing:** misroutes are under 5 % over 100 Auto memos, measured from the
  correction events.
- **Reliability:** zero lost takes; every failed memo is visible and
  retryable.
- **Polish:** I don't open the app for U1–U3.

## Open questions

- **Journal home:** `brain/Inbox/` with `tags: [journal]` for now. A dedicated
  journal folder is a brain decision, deferred.
- **Spoken-replies voice and language:** follow the memo's language. The voice
  is chosen in R2 from audio-gateway's catalog.
- **R6 and the factory's push decision:** decided when R3 is live.
