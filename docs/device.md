# The paired iPhone

Build, signing, install, observability. Scripts: `scripts/device-*.sh`; recipes and the hardware checklist: skill `device`. Rules to follow: `scripts/AGENTS.md` (Device scripts).

`make device` builds, signs, installs, launches Iris and screenshots the phone to `.artifacts/device-<time>.png`
(`device-build`, `device-run`, `device-screenshot` run alone; `make device-run ARGS="-flag"` passes launch arguments). Scripts: `scripts/device-*.sh`;
the phone (`devicectl list devices`, the connected physical iOS device) resolves at runtime, nothing about it is tracked. Overrides: `IRIS_DEVICE_ID`,
`TEAM=<id>`, `DEVICE_SIGNING=paid|personal`. The phone's tunnel may read `disconnected` while it is `available`: the scripts accept that (it comes up on first use), only `unavailable` is skipped.

- **Signing is one switch, paid by default.** `DEVICE_SIGNING=paid` signs with the paid team, headless: `scripts/device-build.sh` reads `team-id`,
  `asc-key-id`, `asc-issuer-id` and `asc-key-p8` from `op://mini/apple-developer` with `secrets-run read` (never `op`), and passes
  `-allowProvisioningUpdates -authenticationKeyPath <file> -authenticationKeyID <id> -authenticationKeyIssuerID <issuer>` plus `DEVELOPMENT_TEAM=<team-id>`
  to `xcodebuild`. The entitlements apply exactly as tracked (`aps-environment`, the App Group, the Keychain group).

- **The App Group is on for paid builds** (verified 2026-11-05, iPhone 15): `group.com.jkrumm.iris` is registered in the developer portal and enabled on
  `com.jkrumm.iris`, `.widgets` and `.notifications` (Push only on `com.jkrumm.iris`), so `make device` signs all three targets with
  `com.apple.security.application-groups` and `aps-environment` (app) and `codesign -d --entitlements -` shows the group on the `.app` and both `.appex`.
  The App Group stays declared for later widgets (owner portal step, no widget code reads it now). A build failing with "Provisioning profile …
  doesn't match the entitlements file's value for the com.apple.security.application-groups entitlement" means the group is missing in the portal or on one
  of the App IDs (the ASC API key cannot create or attach it: owner step, portal > Identifiers > App Groups).
  `make testflight UPLOAD=0` with the tracked entitlements signs with Apple Distribution, `aps-environment` production and the group on the app and both extensions (verified 2026-11-05).

- **The key file's life:** 1Password flattened the `.p8` newlines into spaces, so `pem_normalize` (`scripts/apple-signing-key.sh`, shared by device, TestFlight and Mac release; the same rule as
  `normalizePem` in `server/src/notify/select.ts`) rebuilds real newlines and 64-character body lines into a `mktemp` file with mode 0600; a `trap` on
  `EXIT` deletes it on every exit path. Only the path, key id and issuer id are in argv; the key is in no log and no tracked file.

- **Personal Team is the fallback** (`DEVICE_SIGNING=personal`): the free team Xcode knows (`defaults export com.apple.dt.Xcode`), no key file. It signs
  neither Push nor App Groups, so the three `CODE_SIGN_ENTITLEMENTS` variables (`IRIS_APP_ENTITLEMENTS` etc. in `apple/project.yml`, default the tracked
  files, so the simulator/CI build with `CODE_SIGNING_ALLOWED=NO` is unchanged) point at copies without `aps-environment` and the App Group, derived at
  build time (`entitlement_settings`), so nothing drifts. Limits: 7-day profiles, 10 App IDs per 7 days (`com.jkrumm.iris`, `.widgets`,
  `.notifications` are three; never rename them), 3 devices, no APNs token and no remote Live Activity.

- **APNs on the phone:** `PushRegistrar` (apple/Iris, `PushAppDelegate` forwards the callbacks) registers once a connection is saved and sends the hex token
  with `apnsEnv` through `devices/register`: `sandbox` on a Debug build (`#if DEBUG`, what `make device` installs), `production` on Release (TestFlight).
  `MEMO_DONE` carries Reply, Reply by voice and Play; taps, actions and the Live Activity's Reply/card open `iris://memo/<id>` (`ConversationLink`, `ConversationRouter`). Reply by voice (`focus=voice`) opens the conversation and starts a Hermes take bound to its thread (`ConversationRouter.startVoiceReply`); `TakeRequest.threadID` binds any take to a thread, `holdToTalk` alone marks a thread's hold-to-talk (no take screen/banner/preview); a Hermes start (Control, Siri, Shortcuts) while a conversation with a known thread is on top continues it (`TakeThreadBinding`). Details: TDD §4 Notifications. Only the Iris iOS targets are built by `make device`; `IrisMac` and the test bundles are not.

- **First install:** the first `-allowProvisioningUpdates` build registers the device; the owner must trust the developer once on the phone (Settings >
  General > VPN & Device Management) or `launch` fails with "invalid code signature ... profile has not been explicitly trusted".
  A codesign keychain prompt on the mini's screen needs "Always Allow" (not seen so far: the build signed headless).

- **Screenshot:** `xcrun devicectl device capture screenshot` (Xcode 27). `pymobiledevice3` does not work here: the phone is on a CoreDevice network tunnel,
  `usbmux list` is empty and an RSD tunnel needs root.

- **Connecting the app** has no launch-argument route (no production backdoor): the owner types the server URL and the `iphone` device token once in
  Settings > Connection (Keychain item survives reinstalls over the same bundle id). The tailnet VPN must be on. The phone must be unlocked for `launch`.
  Verified 2026-10-30: a typed memo from the phone reached `done`. Known app gap: Settings says "Connected" for any saved configuration, reachable or not.

- **Device observability (TDD §8):** every capture, route, interruption, outbox, intent and Live Activity event is `DeviceLog.shared.event(...)` (apple/Iris) or
  an `IrisCapture` `CaptureEvents` call: one `os.Logger` line in `com.jkrumm.iris` and one relayed record (`service.name=iris-ios`, trace id = the memo id
  without dashes, ordered by `seq`). Add an event there, not a bare `Logger` call, and never a token, transcript, reply or port uid in one. `service.version` is the
  `IRIS_BUILD_SHA` build setting (`scripts/device-build.sh` passes the short git sha; any other build reports `dev`). The widget extension only logs to the console.
  Delivery is single-flight and bounded (a send ends at 20 s, the background flush holds its assertion at most 20 s), a crash file that cannot be read before the
  first unlock costs nothing (records wait in memory), and records left behind for another server are counted in `dropped` (TDD §8).
  Headless read of a take: skills `device` and `memo-debug`.

