---
name: ios-verify
description: Verify an Iris Apple change — generate the project, boot the pinned simulator, build-run, screenshot, read the UI tree, tap, record/compare snapshots, run the UI tests. Use after any change under apple/ before claiming it works, or to look at the running app.
---

# ios-verify

Pinned simulator: `iPhone 17`, iOS 27.0 (`SIM_NAME`/`SIM_OS` in the Makefile). Generic toolchain recipes: skill `apple-dev`. No MCP (TDD D17).
**Machine budget:** every target below runs through `scripts/apple-slot` (one Apple job at a time on the mini, bare in CI) and leaves no simulator booted: it shuts them down when it ends. Locally at most one targeted run per change; CI (`apple.yml`) proves the rest. A hands-on session (tap, snapshot-ui, several screenshots) sets `KEEP_SIM=1` on `run-sim` / `screenshot` / `ui-snapshot` and ends with `make sim-down`.
Artifacts land in `.artifacts/` (gitignored); `Read` a PNG to look at it. Every target below ran on the mini against Xcode 27.1 (2026-10-27).

| Goal | Command | Notes |
|-|-|-|
| Compile everything + tests | `make check-apple` | theme drift, `swift format lint --strict`, `swift test` per package, build of `Iris` + `IrisMac` |
| Boot the simulator | `make sim` | blocks on `bootstatus -b` (cold ~40 s), idempotent; stays booted until `make sim-down` |
| Build, install, launch the app | `make run-sim` | launches with `-IrisFakeCapture`; prints the pid; ~1-2 min cold; shuts the simulator down after unless `KEEP_SIM=1` |
| Screenshot | `make screenshot [NAME=label]` | full-resolution PNG -> `.artifacts/<label>.png` |
| UI element tree | `make ui-snapshot` | waits `UI_SETTLE` (8 s), writes `.artifacts/ui-snapshot.txt`; refs `e1, e2 ...` |
| View snapshot tests | `make snapshots` / `RECORD=1 make snapshots` | record only after reviewing the diff |
| XCUITest | `make uitest ONLY=<Class>[/<test>]` | with `FakeCapture`; without `ONLY` it refuses locally (the full suite is CI's, `apple.yml`) |

## Drive the UI

```bash
U=$(xcrun simctl list devices available -j | jq -r '.devices["com.apple.CoreSimulator.SimRuntime.iOS-27-0"][]|select(.name=="iPhone 17").udid')
scripts/mbm ui-automation snapshot-ui --simulator-id $U                       # refs are valid for the LATEST snapshot only
scripts/mbm ui-automation tap --simulator-id $U --element-ref e22 --pre-delay 0.5 --post-delay 2
scripts/mbm ui-automation snapshot-ui --simulator-id $U                       # after the tap: shows the detail (BackButton) 
scripts/mbm ui-automation type-text --help ; scripts/mbm ui-automation swipe --help    # shapes only; not driven (no text field in the app yet)
```

Gotchas, all hit while verifying:
- **Always pass `--element-ref`** (not `--ref`); and give `tap` a `--post-delay 2`. A tap without it reported success on the first attempt but the screenshot
  still showed the list; with the delays the navigation happened and the next snapshot listed only the `BackButton`.
- `snapshot-ui` straight after a launch times out ("remote automation session"); `make ui-snapshot` sleeps first.
- Screenshots from `scripts/mbm` are downscaled; use `make screenshot` (simctl, full resolution) for evidence.
- Stop when done: `make sim-down` (after a `KEEP_SIM=1` session).
- A new element the tests or the CLI must find needs an `accessibilityIdentifier` (`history.list`, `history.row`, `memo.detail` exist).

Report evidence (the PNG path, the snapshot lines), not "it works". The Live Activity, Dynamic Island, widget and notification card cannot be
rendered through this path (compile-checked only); those are device-checklist rows (skill `device`).
