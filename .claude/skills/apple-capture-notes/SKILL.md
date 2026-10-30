---
name: apple-capture-notes
description: Verified and unverified iOS/macOS facts for Iris capture — AudioRecordingIntent + Live Activity rule, audio session options, the iOS 26/27 interruption API, the EU Bluetooth caveat, APNs headers and Live Activity payloads. Load before touching IrisCapture, the intents or the Live Activity, so you do not re-research them.
---

# apple-capture-notes

Source: `docs/TDD.md` §4/§13 (capture, session, interruption and EU rows: no research note covers them, so they are TDD claims only) and `docs/research/2026-10-27-{apns-from-bun,swiftui-design}.md` (APNs and Live Activity rows). Summarised, not re-verified this wave. Wave 17 D2 ran the iPhone 15 / iOS 26.6.1 against the rows marked **device**; every other row is still unverified. Anything marked `S1/S2/S3` is a spike (`docs/spikes/`). Treat the
OS-26/27 API names as research-first: check the docs before using one (`/research`).

| Topic | Fact | Status |
|-|-|-|
| Start from a control | `StartMemoIntent: AudioRecordingIntent`; `perform()` starts the engine and `Activity<MemoAttributes>.request(...)`. Apple requires the Live Activity or the recording stops | **device: the Record control starts nothing** (Lock Screen and Control Center; Siri has no phrase, no `AppShortcutsProvider`); a take started in the app works. Likely cause: the intent runs in the extension without the app's handler (I8). TDD claim otherwise |
| Start fallback | If the system refuses a Live Activity start from the background ("Target is not foreground", one forum report): control uses `openAppWhenRun` and the app auto-starts (accepted by the PRD) | S1 decides |
| Audio session | `.playAndRecord`, mode `.default`, options `.allowBluetoothHFP`, `.allowBluetoothA2DP`, `.bluetoothHighQualityRecording` (falls back to HFP; not available in the EU), `setPrefersNoInterruptionsFromSystemAlerts(true)` | documented; S2 for the car |
| Background | `UIBackgroundModes: audio` keeps the app alive during the take; uploads during the take run on a default `URLSession`, the rest after [Stop] on a background session | documented |
| Interruptions | iOS 27: `didBecomeInactive` / `resumptionRecommendation`; iOS 26 fallback: `AVAudioSession.interruptionNotification`. A take pauses at a segment boundary and resumes | **device: a Siri interruption mid-take pauses and resumes cleanly on the iOS 26 branch; a resume from the island (app in the background) and after a lock failed with "engine resume failed"**, the UI kept counting and the audio was lost (I7). iOS 26 uses the `interruptionNotification` branch |
| Route | `availableInputs`, `setPreferredInput` after activation, read back `currentRoute`; the built-in mic while connected to the car's Bluetooth is undocumented | S2 ; **device: picking the AirPods mid-take aborts the app (uncaught `NSException` from `installTap` in `handleConfigurationChange`, I7); a connected AirPods is not picked up mid-take, but is at start** |
| Capture | `AVAudioEngine` input tap -> `AVAudioConverter` -> `AVAudioFile` AAC 16 kHz mono ~32 kbps, 10 s per file; **never `AVAudioRecorder`** | engine recorder not device-verified |
| Live Activity | `ContentState` plain camelCase `{phase, routeChip?, headline?, hasReply}`, `inputName` device-side; < 4 KB; timer via `Text(timerInterval:)`; lifetime 8 h + 4 h on the Lock Screen | **device: renders** recording / paused / processing on the Lock Screen and in the island; without APNs a processing activity never ends and takes over the island (I8) |
| Live Activity push | token registered per memo (`PUT /v1/memos/:id/activity-token`); push-to-start token from `pushToStartTokenUpdates`; payload `aps: {timestamp, event, "content-state"}`, `dismissal-date` on `end`; a push-to-start (`event: start`) must carry an `alert`, `attributes-type` and `attributes` (not sent by the server yet) | S3; server side tested against a local HTTP/2 server only |
| APNs headers | `apns-topic` = bundle id (`.push-type.liveactivity` suffix for Live Activities), `apns-push-type`, `apns-priority` (we send 5 for `update`, 10 for `end`; priority 10 counts against the hourly ActivityKit budget, 5 does not), `apns-collapse-id` = memo id on alerts, ES256 provider token < 60 min old | real Apple hosts not verified |
| Alerts | category `MEMO_DONE`, `thread-id` memo, `mutable-content: 1`, custom key `memo` = memo id; no transcript or reply in the payload | server tested |
| PlayReply from the Live Activity | activates the session and plays `/speech` while the app is suspended | S3; fallback: open the app |

Open owner-side prerequisites: App Store Connect enrolment (TestFlight, signing) and a paired phone (Developer Mode on).
