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

## Findings
_Not run._
