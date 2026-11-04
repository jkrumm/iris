# Apple paid team: what it unlocks for Iris, and how updates reach the iPhone and the Mac

2026-11-04. Two `agw research` deep runs (iOS `01a1a7e9-9a90-76ba-851c-753d70b75f7f`, Mac `01a1a7e9-af0e-766a-8133-ec415509c04f`),
both `done` / `ok`. Claims marked *unverified* are leads to test on the mini, not facts.

## Decision

| Device | Channel | Update UX | Admin needed |
|-|-|-|-|
| iPhone | **TestFlight, internal group** with automatic distribution | TestFlight installs every new build itself | no |
| Mac | **Developer ID + notarization + Sparkle 2**, non-sandboxed, installed in `~/Applications` | Sparkle checks, downloads and swaps the bundle | no (bundle is user-owned, no `.pkg`) |

Rejected: TestFlight / App Store for the Mac (App Sandbox mandatory, 90-day builds, store-managed install into `/Applications`); ad hoc or
development installs on the iPhone (no automatic update, a reinstall per build); Xcode Cloud (the mini already builds, and Xcode Cloud builds
need manual TestFlight group assignment).

## What the paid membership unlocks

- APNs (token auth `.p8`), hence remote Live Activity updates, push-to-start (iOS 17.2+) and the result alert. Xcode development builds talk to
  the **sandbox** host; **TestFlight and App Store builds talk to production**, so `apnsEnv` follows the build channel.
- TestFlight and App Store Connect uploads; Developer ID signing and notarization for the Mac.
- Profiles valid for about a year instead of 7 days; up to 100 devices per product family per membership year.
- App Groups and a team-prefixed Keychain access group without the Personal Team's gating (the widget feed and `last-memo.json` go live).
- Not needed by Iris: CloudKit, Sign in with Apple, In-App Purchase, Associated Domains. Critical Alerts needs a separate Apple approval
  (not wanted: Iris is silent by default).

## iPhone: TestFlight from the mini

- Internal testers are App Store Connect users (up to 100); **no App Review for internal testing** (medium-high confidence: Apple ties review to
  external groups). Tick "Enable automatic distribution" on the internal group so every processed build reaches it.
- A build opens for **90 days** after upload; the pipeline must upload a fresh build well inside that (a scheduled rebuild if `apple/` is quiet).
- Uploads must be built with Xcode 26+ against the iOS 26 SDK (since 2026-04-28).
- **Team** App Store Connect API key (Users and Access > Integrations; an individual key cannot use the provisioning endpoints or notarytool).
  The `.p8` downloads once. One Team key serves TestFlight uploads, `-allowProvisioningUpdates` and the Mac notarization.
- Recipe:
  ```bash
  xcodebuild archive -project apple/Iris.xcodeproj -scheme Iris -configuration Release \
    -destination 'generic/platform=iOS' -archivePath .artifacts/Iris.xcarchive CURRENT_PROJECT_VERSION=<n>
  xcodebuild -exportArchive -archivePath .artifacts/Iris.xcarchive -exportPath .artifacts/export \
    -exportOptionsPlist <plist: method app-store-connect, teamID, manageAppVersionAndBuildNumber false, destination upload> \
    -allowProvisioningUpdates -authenticationKeyPath <p8> -authenticationKeyID <id> -authenticationKeyIssuerID <issuer>
  ```
  `destination = upload` uploads from the export step; otherwise `xcrun altool --upload-app` (altool is deprecated for notarization only, still
  supported for App Store uploads). **Check the flag names with `xcrun altool --help` on the mini:** two sources disagree.
- Archive takes no auth flags; signing happens at export. Whether a headless export cloud-signs or needs a local Apple Distribution certificate
  is *unverified*: try cloud signing first, fall back to a distribution certificate in the login keychain.
- Build number: `CFBundleVersion` is 1-3 dot-separated integers and must grow per version; derive it from the commit count, never commit it.

## Mac: Developer ID, notarization, Sparkle

- Notarization needs a **Developer ID Application** certificate (only the Account Holder creates one), Hardened Runtime, a secure timestamp,
  no `get-task-allow`. `notarytool` only (altool uploads are refused since 2023-11-01), authenticated by the same Team key:
  ```bash
  xcrun notarytool store-credentials iris-notary --key <p8> --key-id <id> --issuer <issuer>
  ditto -c -k --sequesterRsrc --keepParent Iris.app Iris-notary.zip
  xcrun notarytool submit Iris-notary.zip --keychain-profile iris-notary --wait
  xcrun stapler staple Iris.app && xcrun stapler validate Iris.app
  ```
  Staple the app, build the archive (zip or DMG) from the stapled app, then sign the archive with Sparkle's `sign_update` last (stapling changes bytes).
- Headless codesign can fail with `errSecInternalComponent` on a locked keychain: unlock it and `security set-key-partition-list -S apple-tool:,codesign:`.
- **Sparkle 2.10.1** (2026-10-25) is current; the floor is 2.9.6 (local privilege escalation fix), never 2.7.2. EdDSA key from `generate_keys`
  (private key in the keychain, a backup export in 1Password; `--ed-key-file -` in automation, `-s` is deprecated). Info.plist: `SUFeedURL`
  (https), `SUPublicEDKey`, a growing `CFBundleVersion`. `generate_appcast` signs every enclosure and builds deltas.
- **No admin:** Sparkle asks for an administrator only for `.pkg` updates or a bundle it cannot write (e.g. `/Applications` on a standard
  account, or a root-owned bundle). A user-owned bundle in `~/Applications` updates without a prompt. *Unverified on macOS 26*: the only
  counter-report is Sparkle 1 (2018); test it on the MacBook. Never add a custom `NSUpdateSecurityPolicy` (Sparkle #2591).
- **Non-sandboxed.** Sparkle's sandboxed installer XPC path is fragile in practice (a shipped app could not update itself and needed a manual
  reinstall). Iris's Mac app needs nothing the sandbox gives; the microphone is the Hardened Runtime `com.apple.security.device.audio-input`
  entitlement plus `NSMicrophoneUsageDescription`.
- First install: drag from the archive into `~/Applications`; a notarized, stapled app shows the "downloaded from the internet" dialog once,
  no Open Anyway. Sparkle-installed updates carry no quarantine attribute (one spike; check with `xattr -l`).
- Hosting: appcast and archives as **GitHub Release assets of this public repo** (`releases/latest/download/appcast.xml`): reachable without
  the tailnet, no hostname in the tree. The release job writes nothing back to `master`.
- Sandbox questions answered for the record: the Carbon hotkey (KeyboardShortcuts) and a non-activating panel work sandboxed; setting the
  system default input device from a sandbox is *unverified*, another reason to stay non-sandboxed.

## Unverified, test on the mini

`altool` flag names on Xcode 27.1; headless cloud signing at export; one APNs key for sandbox + production (portal shows the key's
environment); Sparkle without a prompt on the MacBook's account; quarantine on Sparkle updates.
