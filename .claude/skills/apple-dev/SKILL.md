---
name: apple-dev
description: The Mac mini's Apple toolchain and recipes — Xcode via xcodes, XcodeGen, xcodebuild build/test/archive, simctl (boot, install, launch, screenshot, push), devicectl, the mobilebuildmcp CLI for UI automation, pymobiledevice3 device screenshots, headless signing, TestFlight. Use before building, running, testing or screenshotting any Apple target (iOS, macOS, widgets) on the mini, or when an xcodebuild/simctl command fails.
---

# apple-dev — Apple toolchain on the mini

Every command below was run on the mini (Xcode 27.1 / 27A9275, Swift 6.4, 2026-10-27) against a scratch XcodeGen app
unless a line says **unverified**. No MCP servers (TDD D17, owner decision): UI automation goes through the
`mobilebuildmcp` CLI. Never start dev servers; simulators are fine, shut them down when done (`simctl shutdown`).

## Toolchain

| Piece | Where | Notes |
|-|-|-|
| Xcode 27.1 | `/Applications/Xcode-27.1.0.app` | `xcode-select -p` points into it; `xcodes installed` shows `(Selected)` |
| `xcodes` 2.1.0 | `~/.local/bin/xcodes` | pinned signed release, `dotfiles/scripts/install-xcodes.sh` (brew build is broken) |
| XcodeGen 2.46.0 | `/opt/homebrew/bin/xcodegen` | dotfiles Brewfile |
| `pymobiledevice3` 11.45.0 | uv tool, `~/.local/bin` | dotfiles `make _setup-tools` |
| `mobilebuildmcp` 2.7.1 | `npx -y` (no install) | pin the version, set `MOBILEBUILDMCP_SENTRY_DISABLED=true` |
| `swift format` | in the toolchain | `.swift-format` at the repo root |

Simulator runtimes installed: iOS 27.0 and 27.1 (`xcrun simctl list runtimes`). Device used below: `iPhone 18 Pro`
(iOS 27.0), UDID from `xcrun simctl list devices available`. **This repo pins `iPhone 17` on iOS 27.0** for snapshots, `make uitest`
and CI (`SIM_NAME`/`SIM_OS` in the root Makefile, verified on the hosted `xcode-27` image); the recipes below work on any device. List more runtimes with `xcodes runtimes`; installing one is
`xcodes runtimes install "iOS 27.1"` or `xcodebuild -downloadPlatform iOS` (**unverified**: both runtimes were already there;
`xcodes` also needs an Apple ID session for downloads, which a headless host may not have).

## Generate, build, test

```bash
xcodegen generate                                     # apple/project.yml -> .xcodeproj (gitignored)
U=<simulator udid>
xcodebuild -project X.xcodeproj -scheme X -destination "platform=iOS Simulator,id=$U" -derivedDataPath .dd.noindex build
xcodebuild -project X.xcodeproj -scheme X -destination "platform=iOS Simulator,id=$U" -derivedDataPath .dd.noindex \
  -resultBundlePath out/test.xcresult test            # Swift Testing + XCTest in one run
xcodebuild ... -only-testing:<TestTarget>/<Suite> test  # one suite (ran)
```

Cold build of a one-view app: 12 s; test run: 26 s. Build-setting spellings verified end to end (`xcodegen` → build green):
`SWIFT_VERSION: "6.0"`, `SWIFT_STRICT_CONCURRENCY: complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`,
`SWIFT_APPROACHABLE_CONCURRENCY: YES`. For a scratch project set `CODE_SIGNING_ALLOWED: NO`. Swift Testing output
(`✔ Test adds() passed`) comes after an empty XCTest line `Executed 0 tests`; that is normal.
**Snapshot runtime pinning:** snapshots only match on the simulator that recorded them, so always pass an exact
destination (`id=` of the pinned device on the pinned runtime, or `name=iPhone 18 Pro,OS=27.0`), never `generic/` or `latest`.
`make snapshots` / CI use that one destination.

## simctl

```bash
xcrun simctl boot $U                      # returns immediately
xcrun simctl bootstatus $U -b             # BLOCKS until ready; took 40 s cold. Always run it before install/screenshot
xcrun simctl install $U .dd.noindex/Build/Products/Debug-iphonesimulator/X.app
xcrun simctl launch $U com.example.scratch            # prints the pid
xcrun simctl io $U screenshot out/shot.png            # works headless, no Simulator.app; Read the PNG to look at it
xcrun simctl openurl $U https://example.com
xcrun simctl push $U com.example.scratch payload.json # {"aps":{"alert":{"title":..,"body":..}}}
xcrun simctl terminate $U com.example.scratch ; xcrun simctl shutdown $U
```

`simctl push` fails with `UNErrorDomain 2003 ... Source is not authorized` until the app has asked for and been granted
notification permission; request it in the app first (or use a UI test). Live Activity pushes via `simctl push`: **unverified**.
`simctl spawn $U log show --predicate 'subsystem == "..."'` logs with `getpwuid_r` noise on stderr; harmless.

## UI automation: `mobilebuildmcp` CLI (no MCP)

```bash
export MOBILEBUILDMCP_SENTRY_DISABLED=true
m() { npx -y mobilebuildmcp@2.7.1 --style minimal "$@"; }
m tools                                                # 72 canonical tools, grouped by workflow
m simulator build-and-run --project-path $PWD/X.xcodeproj --scheme X --simulator-id $U --derived-data-path $PWD/.dd.noindex
m ui-automation snapshot-ui --simulator-id $U          # semantic element tree with refs (e1, e2 ...)
m ui-automation wait-for-ui --help                     # poll for text/settled state
m ui-automation tap|type-text|swipe|batch --help       # act on refs from the LATEST snapshot only
m ui-automation screenshot --simulator-id $U --return-format path
```

`build-and-run` boots, installs and launches (45 s with a fresh build) and writes build, runtime and OSLog logs under
`~/Library/Developer/MobileBuildMCP/workspaces/<project>-<hash>/logs/`. **`snapshot-ui` right after boot or launch times out**
("Timed out creating the simulator remote automation session"); wait ~8 s after launch, then it works (3 s). `tap` and
`type-text` follow the `--help` shapes above and were not driven here (the scratch app had no controls: 0 targets).
Screenshots from this CLI are downscaled JPEGs; use `simctl io screenshot` for full-resolution PNGs.

## Physical device

```bash
xcrun devicectl list devices                          # ran; with no phone it lists only the simulated iPhone 18 Pro
xcrun devicectl device install app --device <id> X.app        # unverified until a phone is paired
xcrun devicectl device process launch --device <id> com.jkrumm.iris   # unverified until a phone is paired
pymobiledevice3 usbmux list                           # ran: [] with no device attached
pymobiledevice3 developer core-device screen-capture screenshot out/phone.png   # CLI exists; unverified without a phone
```

`devicectl` has no screenshot verb; `pymobiledevice3` is the route (needs Developer Mode and a mounted developer image).
Pairing a phone with the mini is an owner step (trust prompt on the phone, Developer Mode on).

## Signing, archive, TestFlight

- `xcodebuild -scheme X -destination 'generic/platform=iOS' -archivePath out/X.xcarchive archive` succeeded for the
  unsigned scratch app (`CODE_SIGNING_ALLOWED: NO`). A signed archive is **unverified until the paid enrolment**.
- Device signing (ran, Personal Team): `xcodebuild … -destination id=<device> -allowProvisioningUpdates DEVELOPMENT_TEAM=<id> build` signs with the one
  Apple Development identity in the login keychain (`security find-identity -v -p codesigning`), headless, no keychain prompt appeared. The team id comes
  from `defaults export com.apple.dt.Xcode - | plutil -extract IDEProvisioningTeamByIdentifier json -o - -` (`isFreeProvisioningTeam`), never tracked.
  A Personal Team profile fails with "doesn't match the entitlements file's value for the com.apple.security.application-groups entitlement" and cannot
  carry `aps-environment`: `scripts/device-build.sh` strips both via the `IRIS_*_ENTITLEMENTS` build settings (`DEVICE_SIGNING=paid` keeps them).
  Remove a key from a plist with `PlistBuddy -c "Delete :com.apple.…"`: `plutil -remove` reads the dots as a key path.
- Headless signing with an App Store Connect API key (`-authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID`, key in 1Password via
  `secrets-run`) is **unverified until enrolment**.
- If codesign ever hangs on a keychain prompt over SSH/launchd: `security unlock-keychain` then
  `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <keychain-pass> <keychain>` (**unverified**, not needed so far).
- Mac apps (MenuBarExtra, hotkey, mic) need a **stable signing identity**: TCC (microphone, accessibility) grants are keyed to
  the code signature, so ad-hoc builds lose the grant on every rebuild. Reset a stuck grant with `tccutil reset Microphone <bundle id>`.
  Unverified until the Mac target exists.
- TestFlight: `xcodebuild -exportArchive -archivePath … -exportOptionsPlist ExportOptions.plist` with
  `method: app-store-connect` and `destination: upload`, or `xcrun altool --upload-app` (the binary exists in this
  Xcode). **Unverified until enrollment**; `make testflight` is a fleet task.

## Failure modes

| Symptom | Cause / fix |
|-|-|
| blank or duplicated screenshot | screenshot before `bootstatus -b` finished |
| `xcodebuild` cannot find a destination | simulator not created for that runtime; `xcrun simctl list devices available` |
| `snapshot-ui` times out | app or sim not settled; wait and retry |
| snapshot test diffs on a clean tree | different simulator or runtime than the reference |
| `Source is not authorized` on push | notification permission not granted |
