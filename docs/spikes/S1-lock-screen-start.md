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
_Not run._
