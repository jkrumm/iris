---
name: device
description: Put Iris on the paired iPhone — devicectl install and launch, device screenshot, log stream, and the hardware-only checklist. Use when something has to run on real hardware (Lock Screen control, background take, mic switch, Live Activity push).
---

# device

Hardware-only rows live in `docs/spikes/device-checklist.md`; spike briefs in `docs/spikes/`. Pairing the phone is an owner step (trust
prompt on the phone, Developer Mode on, one cabled pairing); until then every command here is **unverified until a phone is paired**.
Signing (a team id or an App Store Connect API key from 1Password via `secrets-run`) is unverified until enrolment; see `apple-dev`.

```bash
xcrun devicectl list devices                     # ran: lists only simulated devices today (Reality: simulated); a phone shows "connected" or "available (paired)"
pymobiledevice3 usbmux list                      # ran: [] with no phone attached
D=<device identifier from the list>
xcrun devicectl device install app --device $D <path>/Iris.app        # unverified until a phone is paired
xcrun devicectl device process launch --device $D --terminate-existing com.jkrumm.iris   # unverified until a phone is paired
xcrun devicectl device process launch --device $D --console com.jkrumm.iris              # --console bridges stdout; flag exists (ran --help)
pymobiledevice3 developer core-device screen-capture screenshot .artifacts/phone.png     # unverified; devicectl has no screenshot verb
```

- Build for the device: `xcodebuild -project apple/Iris.xcodeproj -scheme Iris -destination 'id=<device id>' -allowProvisioningUpdates build`
  (signed build unverified until a team id exists; `make` targets use `CODE_SIGNING_ALLOWED=NO` and are simulator-only).
- Logs: `os.Logger` subsystem `com.jkrumm.iris`; `pymobiledevice3 syslog live` is the unverified route, the `--console` launch above for app stdout.
- Server side of a device test: the device token is `op://mini/iris/device-tokens` (device `iphone`); the memo shows up in `GET /v1/memos`, trace via skill `memo-debug`.
- Report each checklist row as pass/fail with the date, device model and iOS version, and append it to the checklist file.
