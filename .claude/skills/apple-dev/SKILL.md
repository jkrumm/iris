---
name: apple-dev
description: The Mac mini's Apple toolchain and recipes — Xcode via xcodes, XcodeGen, xcodebuild build/test/archive, simctl (boot, install, launch, screenshot, push), devicectl, the mobilebuildmcp CLI for UI automation, pymobiledevice3 device screenshots, headless signing, TestFlight. Use before building, running, testing or screenshotting any Apple target (iOS, macOS, widgets) on the mini, or when an xcodebuild/simctl command fails.
---

# apple-dev — Apple toolchain on the mini

Every command below was run on the mini (Xcode 27.1 / 27A9275, Swift 6.4, 2026-10-27) against a scratch XcodeGen app
unless a line says **unverified**. No MCP servers (TDD D17, owner decision): UI automation goes through the
`mobilebuildmcp` CLI. Never start dev servers; simulators are fine, shut them down when done (`simctl shutdown`).

**Machine budget:** every make target below that runs `xcodebuild`, `swift test` or boots a simulator goes through `scripts/apple-slot` itself (Apple lock + `factory slot run --name iris-apple` on the mini, bare in CI) and shuts the simulators down when it ends (`KEEP_SIM=1` keeps one; `make sim-down`). For a raw `xcodebuild` / `simctl` command outside those targets, prefix `scripts/apple-slot` (add `--sim` if it boots a simulator). Never `lockf` by hand. At most one targeted local run per change; test runs are capped (`-parallel-testing-enabled NO`, one destination, `swift test --jobs 2`); `make uitest` needs `ONLY=` locally.

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
- Device signing, paid (default, `DEVICE_SIGNING=paid`): `scripts/device-build.sh` reads `team-id`, `asc-key-id`, `asc-issuer-id`, `asc-key-p8` from
  `op://mini/apple-developer` via `secrets-run read`, rebuilds the `.p8` (1Password flattened its newlines) into a 0600 `mktemp` file, deletes it on exit, and runs
  `xcodebuild … -destination id=<device> -allowProvisioningUpdates -authenticationKeyPath <file> -authenticationKeyID <id> -authenticationKeyIssuerID <issuer> DEVELOPMENT_TEAM=<team-id> build`
  (flags checked against `xcodebuild -help` on Xcode 27.1). The tracked entitlements apply as they are. Details: AGENTS.md "Device".
- Device signing, Personal Team (ran, `DEVICE_SIGNING=personal`): `-allowProvisioningUpdates DEVELOPMENT_TEAM=<id>` signs with the one Apple Development identity in the login
  keychain (`security find-identity -v -p codesigning`), headless. The team id comes from `defaults export com.apple.dt.Xcode - | plutil -extract IDEProvisioningTeamByIdentifier json -o - -`
  (`isFreeProvisioningTeam`). A Personal Team profile fails with "doesn't match the entitlements file's value for the com.apple.security.application-groups entitlement" and cannot
  carry `aps-environment`: the script strips both via the `IRIS_*_ENTITLEMENTS` build settings. Remove a key from a plist with `PlistBuddy -c "Delete :com.apple.…"`: `plutil -remove` reads the dots as a key path.
- Headless signing with the ASC Team key (ran 2026-11-04): the flags above create and download the profiles without Xcode's account (App ID + Push worked). The API key cannot create an App Group
  identifier or attach it to an App ID: the Account Holder registers `group.com.jkrumm.iris` and enables it on the three App IDs in the portal (done 2026-11-05; then the same flags sign all three targets with the group, AGENTS.md "Device").
- If codesign ever hangs on a keychain prompt over SSH/launchd: `security unlock-keychain` then
  `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <keychain-pass> <keychain>` (**unverified**, not needed so far).
- Mac apps (MenuBarExtra, hotkey, mic) need a **stable signing identity**: TCC (microphone, accessibility) grants are keyed to
  the code signature, so ad-hoc builds lose the grant on every rebuild. Reset a stuck grant with `tccutil reset Microphone <bundle id>`.
  Unverified until the Mac target exists.
- TestFlight: see "TestFlight (`make testflight`)" below.

## TestFlight (`make testflight`)

Flag names checked against `xcodebuild -help` and `xcrun altool --help` on Xcode 27.1 (27A9275, 2026-11-04, help text only); what ran is marked.

```bash
make testflight                                  # UPLOAD=0 (default): signed .ipa in .artifacts/testflight/export, then codesign -dvv + aps-environment printed
make testflight UPLOAD=1                         # destination upload: the export step sends the build to App Store Connect
```

- `scripts/testflight.sh`: `xcodegen generate`, `xcodebuild archive` (Release, `-destination 'generic/platform=iOS'`, `CURRENT_PROJECT_VERSION=<git rev-list --count HEAD>.<UTC epoch hours>` (App Store Connect rejects a repeated build number; the weekly same-sha rebuild raises the second component),
  `IRIS_BUILD_SHA`, `DEVELOPMENT_TEAM` from `team-id`), then `xcodebuild -exportArchive -exportOptionsPlist <tracked apple/ExportOptions.plist + teamID + destination>`.
  Both steps get `-allowProvisioningUpdates -authenticationKeyPath <0600 temp file> -authenticationKeyID -authenticationKeyIssuerID` from the ASC Team key
  (`scripts/apple-signing-key.sh`: `secrets-run read op://mini/apple-developer/{asc-key-p8,asc-key-id,asc-issuer-id,team-id}`, `pem_normalize`, `trap` deletes the file). Full output goes to `.artifacts/testflight/testflight.log`, only the tail on failure.
- Export options (`xcodebuild -help`): `method app-store-connect` (`app-store` is deprecated), `destination` `export|upload`, `manageAppVersionAndBuildNumber false` (the build number is ours),
  `signingStyle automatic`, `testFlightInternalTestingOnly true` (the build can never reach external TestFlight or the App Store), `uploadSymbols`.
- The three `Info.plist` files hold a literal `CFBundleVersion`, so the build setting does not reach them: the script sets it in the archive's plists before the export (the export re-signs). Making the plists
  `$(CURRENT_PROJECT_VERSION)` removes the patch step.
- `altool` is not used (the export uploads). If it is ever needed: `xcrun altool --upload-app -f <ipa> --api-key <id> --api-issuer <issuer> --p8-file-path <file>` (`--api-key`/`--api-issuer`, not the older `--apiKey`; `--p8-file-path` avoids the `~/.private_keys` lookup). **Unverified.**
- Cloud signing at export is **unverified until the first run**. If it fails with a missing distribution certificate, the script says so: the Team key needs the Admin role (or an Apple Distribution certificate with its private key goes into the mini's login keychain, Account Holder). It never creates certificates.
  The App Group `group.com.jkrumm.iris` must exist in the portal (Account Holder) or the profile does not match the tracked entitlements. The upload also needs the App Store Connect app record for `com.jkrumm.iris`.
- Poller: `release-hooks.sh` runs this detached after a deploy when `apple/**` changed, weekly otherwise; off without `TESTFLIGHT=1` in `~/.iris/release.env` (AGENTS.md "Release hooks"). A run in progress shows in `~/Library/Logs/iris-release-testflight.log`; one at a time by the Apple lock.

## Mac release (Sparkle)

`make mac-release IDENTITY=development|developer-id [PUBLISH=draft|release]` (`scripts/mac-release.sh`; AGENTS.md "Mac releases"). The target
takes the Apple slot itself; add a deadline with `scripts/apple-slot timeout 2400 make mac-release IDENTITY=development PUBLISH=draft`.

- Tools: Sparkle 2.10.1's `generate_keys`, `sign_update`, `generate_appcast` come with the SPM package
  (`apple/.dd.noindex/SourcePackages/artifacts/sparkle/Sparkle/bin`); a download of the release tarball in `~/.local/share/sparkle/<version>/bin` is the
  fallback (`gh release download <version> -R sparkle-project/Sparkle -p 'Sparkle-*.tar.xz'`, unpack in its own directory).
- EdDSA key: `generate_keys` stored it in the login keychain (works headless); `generate_keys -p` prints the public half; `-x <file>` exports the
  private key (0600, outside every repo; the backup for 1Password). **`sign_update` / `generate_appcast` hang headless on the keychain's access prompt**
  (verified 2026-11-04): always pass `--ed-key-file <exported file>`. Verify with `sign_update --verify --ed-key-file <key> <zip> <edSignature>`
  (exit 1 and "failed to pass signing verification" when wrong). `generate_appcast --ed-key-file <key> --download-url-prefix <url> <dir>` writes
  `<dir>/appcast.xml` from the zip's Info.plist.
- `IDENTITY=development`: Apple Development of the paid team through `-allowProvisioningUpdates` and the ASC Team key, Hardened Runtime and
  `--timestamp`, no notarization, drafts only. `developer-id` needs a "Developer ID Application (<team>)" identity with its private key in the login
  keychain (the mini keeps it in the dedicated `iris-signing` keychain, on the search list with no auto-lock and a partition list that allows `codesign`; a reboot leaves it locked, so the script runs `security unlock-keychain` with the password read from a 0600 file under `~/.local/state/apple-developer/`, overridable with `SIGNING_KEYCHAIN` / `SIGNING_KEYCHAIN_PASS_FILE`; never echo it), then `notarytool submit --key/--key-id/--issuer --wait`, `stapler staple`, `spctl --assess`. Proven 2026-11-05 on the mini as a draft: Accepted, `stapler validate`, `spctl -a -vv -t exec` = `source=Notarized Developer ID`. Sparkle's helpers ship ad-hoc signed and notarization rejects them, so the script re-signs `XPCServices/*.xpc`, `Autoupdate`, `Updater.app`, the framework and the app (in that order, `--options runtime --timestamp`). `notarytool submit --wait` exits 0 on `Invalid`: the script reads the JSON status. Apple's queue can take over 30 min on a new account: the script then prints `RESUME_BUILD=<n> RESUME_NOTARY_ID=<id>` to continue without rebuilding or re-signing.
- Check a signature: `codesign -dvv --entitlements - IrisMac.app` shows `flags=0x10000(runtime)`, `TeamIdentifier`, `Timestamp`, the audio-input
  entitlement, no `app-sandbox`, no `get-task-allow`. `SIGNING_ONLY=1` stops there.
- Drafts are not `releases/latest`; delete a proof with `gh release delete <tag> --yes --cleanup-tag`.

## Failure modes

| Symptom | Cause / fix |
|-|-|
| blank or duplicated screenshot | screenshot before `bootstatus -b` finished |
| `xcodebuild` cannot find a destination | simulator not created for that runtime; `xcrun simctl list devices available` |
| `snapshot-ui` times out | app or sim not settled; wait and retry |
| snapshot test diffs on a clean tree | different simulator or runtime than the reference |
| `Source is not authorized` on push | notification permission not granted |
| `xcodebuild` / `swift package resolve` hangs at "Downloading binary artifact" (an SPM `binaryTarget`, Sparkle) | SwiftPM blocks on its artifact-cache lock while `curl` of the URL takes a second. Put the zip at `~/Library/Caches/org.swift.swiftpm/artifacts/<url with every non-alphanumeric char as _>` (for Sparkle 2.10.1: `https___github_com_sparkle_project_Sparkle_releases_download_2_10_1_Sparkle_for_Swift_Package_Manager_zip`) and resolve again: "Fetched … from cache" |
