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

## Findings
_Not run._
