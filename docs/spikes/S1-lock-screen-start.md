# S1: Lock Screen start and a 30-minute background take

**Question.** Can a `ControlWidget` button run `StartMemoIntent: AudioRecordingIntent` from the Lock Screen, start the engine and request an
`Activity<MemoAttributes>`, and does the take then survive 30 minutes of app switching and screen locks? (TDD §4 Start paths; risk in §13.)

**Why it matters.** The whole product is "press a control, talk". If the system refuses a Live Activity start from the background ("Target is not
foreground", reported once), the control must open the app (`openAppWhenRun`) and auto-start: accepted by the PRD, but a different UX.

**Build.** The smallest app that proves it, in a scratch target or branch (not the full R1): `StartMemoIntent`, the control, an `AVAudioEngine` tap
writing 10 s `AVAudioFile` segments, `MemoAttributes` with a `Text(timerInterval:)`, and `Info.plist` `UIBackgroundModes: audio`. Use `apple/project.yml`
as the base; install with `devicectl` (skill `device`).

**Procedure.**
1. From a locked phone press the control. Record whether a Live Activity appears, whether the timer runs, and whether the recording indicator shows.
2. Repeat from Control Center, from the app, and via Siri ("Record with Iris").
3. 30-minute take: lock the phone, switch between apps, take a call-free walk. Count the segment files at the end (expect 180).
4. Stop from the Live Activity button and from the app.

**Decide.** Pass: the intent path works from the Lock Screen. Fail: write the exact error, switch the control to `openAppWhenRun`, and note
the extra tap in the PRD/TDD. Also record: battery drain over the 30 min, whether iOS killed the app, gaps between segment files (timestamps).

**Evidence.** Device model, iOS version, a screen recording, the file listing with sizes, the `Logger` output (`devicectl ... --console`).

## Run plan (Wave 17 D2, phase 1: written, nothing run)

The app, Control and intents are built (Wave 15 I3/I4), so this is a run of `make device`, not a scratch build. Device: owner's iPhone 15, iOS 26.6.1,
Personal Team. Toolbox, verification recipes and the step order across all spikes: `device-checklist.md` ("Wave 17 D2 run plan"). Step ids `D2-n` are
that file's. Every owner step is one `ask-human.sh ask '<text>' --cmd true`; a click means "owner says done", the outcome is checked headless before a row passes.
A take that never reaches `GET /v1/memos` stops the run and goes to the lead as a data incident.

**D2-1: Lock Screen start, Live Activity, island controls (one take).** Rows 1, 13, 15, 19.
1. Owner: "Lock the phone. Press the Iris control on the Lock Screen. Say: *Check one, Lock Screen start.* Do not unlock. Look for: the Live Activity card with a running timer and the
   orange microphone dot." Headless: `make device-screenshot NAME=d2-1-lock` (if the screenshot of a locked phone is refused, the owner's Run/Deny and the next step's
   proof stand in, noted as such); `devicectl device info lockState` says locked; poll `GET /v1/memos?limit=3` every 10 s: a new memo `device: iphone`, state `receiving`
   (row 19: segments arrive while the take runs; `GET /v1/memos/:id` has no count until `complete`, so the proof is the poll seeing the memo and, after the stop, `segmentCount`).
2. Owner: "Unlock to the home screen, leave the app. Look at the island: compact (record dot, time)." Screenshot `d2-1-compact`.
3. Owner: "Long-press the island to expand it. Look for Stop, mic swap, Pause." Screenshot `d2-1-expanded`.
4. Owner: "Tap Pause, wait 3 s." Screenshot `d2-1-paused` (timer frozen, phase paused). Then "Tap Resume, tap mic swap, say: *Check two, after the swap.*" Screenshot `d2-1-resumed`.
5. Owner: "Tap Stop in the expanded island." Headless: the memo reaches `done` (poll `GET /v1/memos/:id`), `segmentCount >= 2` (a pause and a swap each roll a segment), `transcript` holds "Check one" and "Check two"
   (no audio lost across the pause), a final screenshot shows the activity done or gone.
Pass when: the card and the timer appear without unlocking (intent path works from the Lock Screen), every island button acts (screenshots show the phase and the input change),
the memo completes with both sentences. Fail: write the exact symptom; the fallback is `openAppWhenRun` + auto-start (needs an I item, reported to the lead with evidence).

**D2-2: Control Center start, Lock Screen stop.** Rows 1, 3.
Owner: "Swipe down Control Center, press the Iris control (add it first if missing, step D2-0), say: *Check three, Control Center.* Lock the phone. On the Lock Screen card press Stop." Headless: the memo appears (device `iphone`, `receiving`), the Lock Screen screenshot `d2-2-lock` shows the card, and after the Stop the memo is `done` with "Check three".
Pass: take starts from Control Center; the stop from the Live Activity ends it and `complete` is sent (memo leaves `receiving`).

**D2-3: Siri start, banner, stop in the app.** Rows 1, 3, 16.
Owner: "Say 'Hey Siri, Record with Iris' (phone locked or not). Say: *Check four, Siri.* Unlock, open Iris, switch to History. Look for: the compact banner at the top with a running time and Stop." Screenshot
`d2-3-banner`. Then "Open the banner (it opens the take screen) and tap Stop in the app." Pass: the intent starts via Siri; the banner shows; the app Stop ends the take and the memo is `done` with "Check four".
If Siri cannot find the phrase, record that (the intent is only discoverable once the Shortcuts app has indexed it) and use Shortcuts > Iris > Record as the stand-in.

**D2-9: the 30-minute take (S1 step 3).** Rows 2, 7, 19.
Prep screenshot of the battery percentage (D2-0 enables it) `d2-9-start`, then:
1. Owner: "Lock the phone, press the Lock Screen control. Say: *Thirty-minute take, start.* Put the phone in a pocket and carry on. For the next 30 minutes: switch between apps twice, lock and unlock it a few times,
   take a call-free walk. Do not open Iris." (I record the clock time of the click: 0:00.)
2. At 0:10 I ask: "Turn on Airplane Mode now (Control Center)." At 0:12: "Turn Airplane Mode off." (row 7: segments queue and then upload; I poll the memo to see the memo exist from before the airplane window).
   Note: Airplane Mode drops the tailnet VPN; it must come back on its own, else the owner re-enables it (noted, a finding if it does not).
3. At 0:30 I ask: "Press Stop on the Lock Screen card." Headless: memo `done`; `segmentCount` = 180 (+/- 1 for the stop instant); `audioSeconds` within 2 s of the wall-clock time between the click and the stop
   (a gap > 1 s per boundary shows as a shortfall; `curl /v1/memos/:id/audio | ffprobe` for the duration); a screenshot at the end `d2-9-end` for the battery percentage; `devicectl device info processes` every 5 minutes: the Iris process id
   never changes (iOS did not kill the app); no duplicate segment on the server (sha256 idempotence: `segmentCount` is exactly the number of indices).
Record: battery drop in percentage points (working bar: under 10 pp over 30 minutes), whether iOS killed the app, the largest apparent gap.

## Findings

Run 2026-10-30, iPhone 15 (`iPhone15,4`), iOS 26.6.1, Personal Team, build `5ecd5c9` (master + #49 + the D1b outbox fix), app 1.0 (1). Evidence under `.artifacts/` on the mini (untracked).
Every take the owner recorded reached the server and the phone's outbox ended empty; the two crashes and the early recorder deaths below lost audio inside a take, never a whole take that had a closed segment.

**Verdict: S1 fails on the central question.** The Record control starts nothing; a take started in the app, and everything after the start, works except where the recorder dies (I7).

| Question | Result |
|-|-|
| Record control, Lock Screen (locked) | **Fail.** Pressed 12:42Z with the control visible: no memo, no Iris process (only the `IrisWidgets` extension pid in `devicectl device info processes`), `outbox.json` untouched, no crash log. No Live Activity. |
| Record control, Control Center (unlocked) | **Fail**, same: `d2-1-cc-press.png` is the home screen, no island, no recording dot. Cause not visible headless (no log route, below); the intent file says `perform()` needs the app's `CaptureIntents.handler`, so the likely cause is the intent running in the extension process without it (`StartMemoError.appNotReady`, thrown silently). Fix in Wave 17 I8. |
| Siri "Record with Iris" | **Fail.** Siri opened Spotify (the owner said so in the take's own transcript): there is no `AppShortcutsProvider`, so the intent has no spoken phrase. Proposed fix: an `AppShortcutsProvider` with a phrase using `\(.applicationName)`. |
| Take started in the app | Pass. Lock Screen card: Recording, running timer, `Auto`, the input name, Stop / mic swap / Pause (`d2-1-take-07.png`); compact island: waveform glyph, timer, orange microphone dot (`d2-1-take-02.png`). |
| Island controls | Pause **pass** (`d2-1-island-03.png`: expanded island shows Paused, Stop, mic swap, Resume; audio stops at 18.3 s). Resume **fail** ("engine resume failed", memo `1c193eab`). Stop **pass** (memo `1444a1bd`, 24.9 s). Mic swap not tried (see S2). |
| Stop from the Lock Screen card | Pass: the take survived a lock, the audio during the lock is in the memo, Stop on the card ended it and `complete` followed within a second (memo `14427935`, 28.7 s, 3 segments). |
| Stop in the app and the compact banner | Pass (memo `ddaad4d8`, 5 segments), but see failure 4. |
| Segments upload while the app is in the background | Pass: a memo exists on the server about 10 s after the start, long before the stop. |
| **30-minute take** (started in the app, locked, pocket, apps switched, Airplane Mode 13:55 to 13:57Z) | **Pass.** Memo `53745cb2`: 183 segments (>= the 180 expected), 1856 s of audio (the 1.4 % over the wall clock is AAC encoder priming per file: 183 x ~0.14 s), no silence of 1 s or more in the concatenated file (`ffmpeg silencedetect`), the Iris process id never changed (6402, so iOS did not kill the app; the one `none` in the monitor is the Airplane Mode window when `devicectl` lost the phone), the segments queued while offline went up afterwards and `complete` succeeded with no duplicate. Battery about 69 % before, 65 % eleven minutes after the stop (about 4 pp, under the 10 pp bar). The tailnet came back on its own after Airplane Mode. |

Failures found on the way:
1. **The recorder dies and the UI keeps saying RECORDING (data loss, I7).** Memo `8cffd169`: at about 41 s, as the owner locked the phone with the island expanded, the take screen showed `RECORDING 0:51`, then `1:04`, with the red text "The recorder stopped: engine resume failed" (`d2-1-take-10.png`, `-13.png`); the server has 41.4 s and the transcript stops mid-sentence. Memo `8ba6239b` stopped itself 10 s into a take (1 segment, owner: "the recording stopped and is kind of lost"). Locking is not the trigger on its own: the 30-minute take and `14427935` survived it.
2. **Island Resume fails** (`1c193eab`, `d2-1-island-04.png` "engine resume failed", recording gone after the pause). Resume runs from a `LiveActivityIntent` with the app in the background, where the system refuses to start an audio engine; resume needs to run as an `AudioRecordingIntent` or open the app (hypothesis from the evidence, there is no log to confirm).
3. **Stale "Processing" Live Activities (I8).** Without APNs nothing moves a handed-over activity on, so every finished take left a "Processing, Iris is working on it" card with a timer counting up for hours (`d2-1-take-07.png`: 4:27 and 2:49 next to a 0:41 recording). The system then picked a stale one for the island: the compact and expanded island showed it instead of the running take (`d2-1-take-02.png`, `-03.png`), so the island's Stop / Pause / mic swap were unreachable until the owner dismissed the old cards. Fix: with no APNs token the client follows the memo to `done` itself and ends the activity.
4. **A segment open when the app dies is lost as audio.** A kill, a crash or a recorder failure leaves the open segment as an unfinalised m4a (no `moov` atom; ffprobe: "moov atom not found"), which the next launch's sweep moves to `capture/quarantine/` (Settings shows it under "Set-aside files": 3 files, 166 KB). Three such files exist: the tail of a banner stop that hit a 0x8BADF00D scene-update watchdog (`Iris-2026-10-30-135713.ips`, memo `ddaad4d8`), the tail of the headless kill (`607e6a51`, about 4 s, the owner counted to 29 and the server transcript ends at 24), and the open segment of `8ba6239b`. The "at most the last 10 s" promise holds, but the lost seconds are unreadable. Proposed fix: write segments in a crash-safe container (fragmented MP4, CAF or ADTS) so the sweep can adopt a truncated file, or close the file on any recorder failure.
5. **A crash on engine reconfiguration (I7).** Two aborts, one stack (`Iris-2026-10-30-142452.ips`, `Iris-2026-10-30-143927.ips`): `NSException` from `-[AVAudioNode installTapOnBus:bufferSize:format:block:]` in `AVAudioEngineSegmentRecorder.installTap(on:format:converter:target:sink:)` <- `InputTapEngine.installTap()` <- `EngineStartup.bringUp` <- `installTapAndStartEngine(sink:)` <- `handleConfigurationChange()` <- `observeConfigurationChanges()`. See S2.

Logs: no headless route. `log collect --device*` needs root, `devicectl device sysdiagnose` fails (`DiagnoseError`), `devicectl --console` shows stdout only. What worked, read-only: screenshots (the Lock Screen and island too, but only with the display on: a sleeping phone gives a black frame), `devicectl device info lockState|processes|apps|files`, `device copy from` of `outbox.json`, the quarantine files and the crash reports (`--domain-type systemCrashLogs`), the server memo.

### Control fix (Wave 17 I8)

**Cause (Wave 17 I8, from Apple's docs, fix device-unverified).** `StartMemoIntent` conformed to `AudioRecordingIntent` only. A control's
`AppIntent` is performed in the widget extension unless it conforms to `LiveActivityIntent` (or `AudioPlaybackIntent`,
`ForegroundContinuableIntent`, `openAppWhenRun`): then the system launches the app process (in the background, without opening it) and performs
it there. In the extension the handler (registered by the app's composition root) is `nil`, `perform()` threw `appNotReady` and the control
swallowed it. A Live Activity may also only be started from the background through a `LiveActivityIntent` (otherwise "Target is not foreground").
Not the cause: the intent being compiled into both targets (the supported pattern), the Personal Team (no documented effect on intents,
controls or a local `Activity.request`; it only removes remote Live Activity pushes).

**Fix.** `StartMemoIntent: AudioRecordingIntent, LiveActivityIntent`. No `openAppWhenRun` (deprecated, errors in extensions), no
`supportedModes` (a control overrides it). Handler registration already happens in `CompositionRoot.init`, which `IrisApp` builds at launch, so a
background launch has it before `perform()` runs. If the control still does nothing after this, log `systemContext.currentMode` in `perform()` to
see which process ran it.

**Open (device):** a control tap (Lock Screen and Control Center) starts a take with a Live Activity. Unverified until the owner presses it on the phone.

### Re-test after Wave 17 I7/I8/I9/I10 (2026-10-30 evening, build `459a517`, iPhone 15, iOS 26.6.1)

Detail and evidence: `device-checklist.md`, section "Wave 18 D1". **Verdict: S1 is half answered.** Control Center starts a take through the `LiveActivityIntent` fix and opens the app (memo `a66fc402`), which is the PRD's accepted fallback. The Lock Screen control still does nothing, also after the owner unlocks; Apple's rule is that a Lock Screen button is inactive until the device is unlocked, so "start without unlocking" cannot be a pass criterion for a button, and the remaining no-op after unlock is unexplained (no log, see below). Island Resume still fails (`cd6f0e19`: "engine resume failed"), the stale "Processing" activity still outlives its take, and Stop from the History banner no longer hits the watchdog (`3fefefed`). The `ddaad4d8` tail is an unfinalised m4a with no sample table and cannot be recovered with stock tools.
Next: instrument the app first (Wave 18 I6: `IrisTelemetry` is not imported by any app source, so HyperDX has no `iris-ios` data); the research notes in the checklist list the error codes and fields (`!rec` 561145187, `!int`, `!pla`; `IntentSystemContext.currentMode`) that would turn the Resume and Lock Screen failures into a cause.
