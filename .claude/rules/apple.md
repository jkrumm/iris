---
description: Iris invariants for the Apple targets and packages (capture, outbox, Live Activity, contracts)
paths: ["apple/**"]
---

# Iris Apple Invariants

Generic Swift lives in `.claude/rules/swift.md`; this file is what only Iris has. Design: `docs/TDD.md` §4–§8.

- **Never `AVAudioRecorder`** (TDD D5, §4 Capture engine). Capture is an `AVAudioEngine` input tap, `AVAudioConverter`, one
  `AVAudioFile` (AAC, 16 kHz mono) per segment. A recorder stop/start drops audio; continuous buffers keep the server-side concat gapless.
- **Segments rotate** every 10 s of frames, on a mic switch and on an interruption (D4). Each closed file goes to the `Outbox`; a crash
  loses at most 10 s. The rotation and the outbox state machine are pure types (`SegmentRotator`, `OutboxStateMachine`) tested on fakes.
- **Outbox contract:** one persistent entry per (memo, segment), uploads idempotent by index and sha256 (same bytes no-op, different
  bytes 409), retries survive relaunch, `complete {segmentCount}` only after every index is uploaded. Never delete a segment file
  before the server has acknowledged it.
- **The memo id is minted on the client** (UUID v4 at record start) and is the trace id with the dashes stripped (D8).
- **Live Activity** (TDD §4): the whole `ContentState` stays far below Apple's 4 KB limit, `headline` is ≤ 60 characters, no
  transcript or reply text in it. `routeChip` and `headline` are optional and omitted, never null; `inputName` is device-side only
  (the server never sends it), so the Swift `ContentState` declares it optional. Elapsed time is `Text(timerInterval:)`, not a ticking state.
- **Contract fixtures are the API source of truth** (D9): `contracts/fixtures/*.json` decode into `IrisCore` types, and a fixture
  without a mapped Swift type fails the suite. Change the wire format in `server/` first (`make contracts`), then the Swift side.
  Never hand-write a request or response shape that a fixture already defines.
- **UI tests and snapshots use `FakeCapture`** (launch argument `-IrisFakeCapture`): no microphone, no real recorder. Real audio is
  verified on hardware only (`docs/spikes/device-checklist.md`).
- **Snapshots** only compare on the pinned simulator (`SIM_NAME`/`SIM_OS` in the Makefile). Re-record with `RECORD=1 make snapshots`
  and review the PNG diff; never re-record to silence a failure you cannot explain.
- **No real hosts, tokens or emails** in fixtures, sample data, previews or tests: `example.com`, `<domain>`, fake tokens. The
  server URL and device token live in the Keychain (settings), never in a tracked file.
- **Packages depend on each other only through `IrisCore`.** Ports (`SegmentRecorder`, `Outbox`, `APIClient`, ...) are protocols with
  in-memory fakes shipped in the package; no mocking frameworks.
- **Capture facts are in `apple-capture-notes`** (session options, interruption API, Live Activity start rule, APNs headers); load it
  before touching `IrisCapture` or the intents. Anything not device-verified is marked so there; do not state it as fact elsewhere.
- **No spacing literals in views.** Every padding, stack/grid spacing and inset is a step or role of `Theme.Spacing` (`IrisUI/Theme/Spacing.swift`: `hair…xl` steps, `screenMargin`, `sectionTop`, `rowVertical`, `chipGap`, `barInset`, ...), derived from `docs/design/mockups/*.css`. A value the scale lacks is added there (with the mockup it comes from), never typed in a view. Control sizes (a 44 pt button, a 3 pt dash) are not spacing.
- Verify with `make check-apple`; look at UI changes with `make run-sim` + `make screenshot` (skill `ios-verify`).
