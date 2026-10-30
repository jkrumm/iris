# S2: Mic switch mid-take

**Question.** Can the take switch input (iPhone mic <-> AirPods <-> the car's Bluetooth) without losing audio, and can the built-in mic be forced
while the phone is connected to the car? (TDD §4 `RouteManager`; §13 "undocumented".)

**Build.** The capture spike from S1 plus `AudioSessionController` (`.playAndRecord`, `.allowBluetoothHFP`, `.allowBluetoothA2DP`,
`.bluetoothHighQualityRecording` with HFP fallback) and a `RouteManager` that lists `availableInputs`, calls `setPreferredInput` after activation
and reads back `currentRoute`. Rotate the segment on every route change (`rotate(for: .micSwitch)`).

**Procedure.**
1. Start a take on the built-in mic, connect AirPods mid-take, then disconnect. Log `currentRoute` and the segment boundaries.
2. `setPreferredInput` to the built-in mic while AirPods are connected; then to the AirPods.
3. In the car: connect over Bluetooth, start a take, record the active input. Try `setPreferredInput(builtInMic)` and speak: is the audio from the
   phone or the car? Note the A2DP/HFP sample-rate behaviour and the audio quality.
4. Play back the concatenated result (`GET /v1/memos/:id/audio`) and listen for gaps at the boundaries.

**Decide.** Per route: the achievable input and whether a per-route rule (`[routeFingerprint: preferredPortUID]`) holds. Record the EU
`.bluetoothHighQualityRecording` behaviour if the device region allows testing.

**Evidence.** Device model, iOS version, route dumps, the segment file list around each switch, a listening note.

## Run plan (Wave 17 D2, phase 1: written, nothing run)

Built and unit-tested already (`RouteManager`, `switchInput`, per-route rules, segment rotation on a route change); this run is the hardware half. Device: owner's iPhone 15, iOS 26.6.1
(so the EU `.bluetoothHighQualityRecording` clause cannot be tested unless the phone's region is EU: record the region setting). Toolbox and the step order: `device-checklist.md`
("Wave 17 D2 run plan"). Owner steps are `ask-human.sh ask '<text>' --cmd true`, a click is "owner says done"; every take must reach `GET /v1/memos`.

To make a lost second visible without listening: the owner speaks a numbered sentence per phase ("Phase one, built-in microphone." ...), so the transcript proves each phase's audio survived,
and `segmentCount` must exceed `audioSeconds / 10` by one segment per route change (each switch rolls a segment).

**D2-6: AirPods in and out mid-take, forced built-in, back.** Rows 4 (and the iPhone half of S2 steps 1, 2, 4).
Needs: AirPods paired, in their case, nearby.
1. Owner: "Open Iris, start a take with the record button on the built-in mic. Say: *Phase one, built-in microphone.*" Screenshot `d2-6-builtin` (take screen mic chip shows iPhone).
2. Owner: "Take the AirPods out and put them in. Wait for the connect chime. Say: *Phase two, AirPods.*" Screenshot `d2-6-airpods` (chip shows AirPods; Live Activity input name if the phone is unlocked and the card visible).
3. Owner: "Open the mic picker (take screen) or the island mic swap and choose iPhone. Say: *Phase three, forced built-in.*" Screenshot `d2-6-forced`. (S2 step 2: `setPreferredInput` to the built-in mic while AirPods are connected.)
4. Owner: "Swap back to the AirPods. Say: *Phase four, AirPods again.*" Screenshot `d2-6-back`.
5. Owner: "Put the AirPods back in the case (disconnect). Say: *Phase five, back on the phone.* Then Stop." Screenshot `d2-6-end`.
Headless verification after the stop: memo `done`; `segmentCount >= audioSeconds/10 + 4`; the transcript holds all five phases in order; `audioSeconds` within 2 s of the wall clock; the five screenshots show the input name changing
(the "Live Activity shows the input name" half of row 4 is read from the island/card when the owner unlocks; if the card is not captured it is noted, not passed).
Pass: a boundary and continued audio on every switch, the forced built-in holds while AirPods are connected (screenshot 3), the chip follows every change. Record the route dump if a diagnostics view/log exists; otherwise
the screenshots are the evidence and the missing dump is a finding (the `Logger` route logs are not readable headless, see the toolbox).

**D2-10: the car (S2 step 3, row 5).** Needs the owner in the car (parked is enough), phone paired to the car's Bluetooth.
1. Owner: "In the car, with the phone connected to the car over Bluetooth, start a take with the Lock Screen control. Say: *Car one, car microphone.*" Screenshot `d2-10-car` (which input the app shows).
2. Owner: "Swap the mic to iPhone (island or take screen). Tap the phone body three times, then say: *Car two, forced phone microphone.*" Screenshot `d2-10-forced`.
3. Owner: "Swap back to the car, say: *Car three.* Stop." Headless: memo `done`, the transcript holds the three phases, `segmentCount >= audioSeconds/10 + 2`. Pass when the app reports the built-in mic while the car is
   connected AND the owner's listening note holds (a final `ask-human.sh` question: Run = "phase two sounded like the phone, not the car's microphone"); the sample-rate/quality note is written from the owner's
   answer and `ffprobe` (stream sample rate is 16 kHz AAC by design, so the car's HFP narrowband shows as bandwidth: check with a spectrogram only if the owner reports it sounds thin).
   If the OS refuses the preferred input (the app still reports the car), the limitation is the finding and TDD §13's "undocumented" line becomes "refused on iOS 26.6.1".

## Findings

Run 2026-10-30, iPhone 15, iOS 26.6.1, build `5ecd5c9`. **Verdict: S2 fails on the phone side and the car is not run.**
- **AirPods in mid-take do not switch the input.** The owner put the AirPods in during a take: the chip stayed on `iPhone-Mikrofon`; the sheet listed both inputs (`iPhone-Mikrofon`, <AirPods name>, `d2-6-mic-05.png`), so `availableInputs` updates live. A take started with the AirPods already connected picked them (chip <AirPods name>, `d2-8b-prekill.png`).
- **Switching to the AirPods mid-take crashes the app** (memo `0cbda45f`: 34.1 s up to the pick, nothing after; the Live Activity stayed and the app was gone on reopen). Crash report `.artifacts/Iris-2026-10-30-142452.ips`: SIGABRT from an uncaught `NSException` thrown by `-[AVAudioNode installTapOnBus:bufferSize:format:block:]`, reached through `AVAudioEngineSegmentRecorder.handleConfigurationChange()` -> `installTapAndStartEngine(sink:)` -> `EngineStartup.bringUp` -> `installTap(on:format:converter:target:sink:)`. A second abort with the same stack came on tapping Record with the AirPods connected (14:39, `Iris-2026-10-30-143927.ips`, no memo: the take died before its first segment closed). The usual cause of that exception is a tap format whose sample rate no longer matches the node's (the AirPods' HFP route); proposed fix (I7): read the node's current format after the configuration change, refuse a zero sample rate or channel count, never let `installTap` throw an Objective-C exception (validate first), and on failure move the take to `failed` where the user sees it.
- Phases 3 to 5 (forced built-in while connected, back, disconnect) were therefore not reachable; island mic swap likewise.
- **Car (S2 step 3, row 5): not run** (no car session). The "built-in mic while connected to the car's Bluetooth" question stays open in TDD §13.
- `.bluetoothHighQualityRecording` in the EU: not exercised (the phone is German-language, region not checked and probably the EU; no route got far enough to show which Bluetooth profile was used).
Rerun D2-6 and D2-10 after I7, with the numbered phrases above.
