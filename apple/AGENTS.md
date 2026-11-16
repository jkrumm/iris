# apple/ (iOS app, Mac app, Swift packages)

Design is `docs/TDD.md` §4 (iPhone) and §5 (Mac). Generic Swift is `.claude/rules/swift.md`. Capture and outbox rules: `apple/Packages/IrisCapture/AGENTS.md`; the shared UI, spacing and artifacts: `apple/Packages/IrisUI/AGENTS.md`; the Mac app: `apple/IrisMac/AGENTS.md`. Feature design behind the iPhone screens (composition, thread view, take UI, live preview, kinds and modes, strings, UI tests): `docs/apple-app.md`; read it before changing those screens. The paired phone and its signing: `docs/device.md`.

## Build and verify

- `apple/Iris.xcodeproj` is generated and gitignored: edit `apple/project.yml`, then `make generate`. A new file under `apple/IrisMac` or another app target needs `make generate` before it builds.
- Apple targets run only where `xcodebuild` exists; on Linux and in the CI `check` job they are skipped, and `apple.yml` on the hosted `xcode-27` runners is the Apple gate. Run at most one targeted Apple job locally per change (`make check-fast` first); the machine budget is in the root file.
- Look at a UI change with `make run-sim` and `make screenshot` (skill `ios-verify`); prove a change as a lead with `make proof-apple`. `xcodebuild` leaves `apple/.dd.noindex`, per-package `.dd.noindex` and `.build`, and `make screenshot` writes `.artifacts/`; all are gitignored.
- `scripts/mbm tap` needs `--element-ref` from the latest `snapshot-ui` and `--post-delay 2`; a `snapshot-ui` straight after a launch times out (`make ui-snapshot` waits first).
- Real audio, the Control press, a background take, Bluetooth and Live Activity rendering are verified on hardware only (`docs/spikes/device-checklist.md`, skill `device`). Say so when a change relies on them; the engine, interruption and route-change paths are covered by fakes only until that check passes.

## Rules for every Apple target

- Wire shapes come from `contracts/fixtures/*.json` and decode into `IrisCore` types; never hand-write a request or response shape that a fixture defines. Change the server first (`make contracts`), then Swift.
- Packages depend on each other only through `IrisCore`. Ports (`SegmentRecorder`, `Outbox`, `APIClient`, …) are protocols with in-memory fakes shipped in the package; no mocking frameworks.
- The memo id is minted on the client (UUID v4 at record start) and is the trace id with the dashes stripped.
- Device events go through `DeviceLog.shared.event(...)` (Mac: `MacEvents`) or an `IrisCapture` `CaptureEvents` call, never a bare `Logger`; one event is one local log line and one relayed record. Never put a token, transcript, reply, URL or device id in one.
- No real hosts, tokens or emails in fixtures, sample data, previews or tests (`example.com`, `<domain>`, fake tokens). The server URL and device token live in the Keychain via Settings, never in a tracked file.
- Every user-facing string has a `de` entry and `make check-strings` enforces it. A SwiftUI literal is a `LocalizedStringKey`, a `String` is `String(localized:comment:)`, and in a package every literal passes `bundle: #bundle`; use `Text(verbatim:)` for data and `// l10n:ignore <why>` for real data. A step name shown to the user is `MemoStep.title`, never `rawValue`. Run in German with `-AppleLanguages "(de)" -AppleLocale de_DE`.
- Snapshots compare only on the pinned simulator (`SIM_NAME` / `SIM_OS` in the Makefile): a diff on a clean tree means a different runtime, and they do not render the glass layer. Re-record with `RECORD=1 make snapshots` and review the PNG diff; never re-record to silence a failure you cannot explain.
- UI tests use `FakeCapture` (`-IrisFakeCapture`): no microphone, no real recorder. They derive from `IrisUITestCase` and wait with `waitForPresence`, `waitForAbsence` and `revealRow(containing:in:)`, which ask again when a query times out on a loaded runner; never loop on `exists` or `frame`. Pin the clock with `-IrisSampleNow` and hold app timers (`-IrisUndoSeconds 600`, `-IrisCopiedSeconds 600`) instead of racing them.
- A new screen or UI-test class goes into `scripts/uitest-map.json`; `bun test scripts` fails on a class the map does not name.
- App icons: `apple/branding/logo.svg` is the one logo source; never redraw it. A changed logo is `make icons` and a commit (the PNGs are committed).
- The Keychain round-trip unit test cancels on the unsigned simulator build (`-34018`); it is device-verified only.
