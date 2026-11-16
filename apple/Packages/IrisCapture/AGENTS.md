# IrisCapture (session, segment rotation, outbox)

Design is `docs/TDD.md` §4 (Capture engine, Outbox). Load skill `apple-capture-notes` before touching capture, the intents or the Live Activity: it holds the verified and unverified iOS facts, and anything not device-verified stays marked there. The long form of every rule below, with the failure that taught it: `docs/apple-capture.md`; read it before changing the outbox, the take lifecycle or the recovery sweep.

## Capture

- Capture is an `AVAudioEngine` input tap, `AVAudioConverter` and one `SegmentWriter` per segment (`AVAssetWriter`, fragmented m4a, AAC 16 kHz mono). Never `AVAudioRecorder` (a stop and start drops audio) and never `AVAudioFile`, whose m4a has no index until it is closed and is unreadable after a kill. Continuous buffers keep the server-side concatenation gapless.
- A segment rotates every 10 s of frames, on a mic switch and on an interruption. A crash loses about a second; the startup sweep adopts the open file. A file that does not play is set aside, never deleted. The rotation and the outbox state machine are pure types (`SegmentRotator`, `OutboxStateMachine`) tested on fakes.
- A failed take releases the microphone through `failTake`; the audio session stays active until every recorder stop has returned and the take is over, and `stop()` and `cancel()` deactivate it behind the take gate.
- A resume that the system refuses while the app is not active keeps the take paused (`CaptureError.sessionRefused`, retried when the app becomes active, bounded by `backgroundResumeLimit` of 10 min). The Live Activity elapsed time is `Text(timerInterval:)`, never a ticking state. A pause keeps the engine running and drops samples, because starting an engine in the background is refused.
- Do not use `.mixWithOthers`; the owner ruled it out.

## Outbox

- One persistent entry per (memo, segment). Uploads are idempotent by index and sha256 (same bytes no-op, different bytes 409), retries survive relaunch, and `complete {segmentCount}` goes only after every index is uploaded. Never delete a segment file before the server has acknowledged it.
- A take is created on the server at its first segment, so a cancelled take leaves nothing behind. A take cancelled after the server may have created its memo queues a persisted `DELETE` (`OutboxDeletion`).
- An outbox file that cannot be decoded is never emptied: Settings "Reset outbox" quarantines it (`outbox.quarantined-<UTC timestamp>.json`). `CaptureStack` never falls back to an in-memory queue.
- Work is bound to the server it was queued for (`serverKey`): the state machine hands out nothing bound to another server, and `ReconfigurableAPIClient` checks it when it picks its target.
- The outbox stalls a transfer on a refusal (`PermanentTransferError`) or after 10 non-transient failures; no network, a 5xx, a 408 and a 429 are `TransientTransferError` and never count.
- The Live Activity `ContentState` stays far below Apple's 4 KB limit, with `headline` at most 60 characters and no transcript or reply text. Optional-field rules: `contracts/AGENTS.md`.
