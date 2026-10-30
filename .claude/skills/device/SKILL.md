---
name: device
description: Put Iris on the paired iPhone — make device (build, sign, install, launch, screenshot), devicectl install and launch, device screenshot, log stream, and the hardware-only checklist. Use when something has to run on real hardware (Lock Screen control, background take, mic switch, Live Activity push).
---

# device

Hardware-only rows live in `docs/spikes/device-checklist.md`; spike briefs in `docs/spikes/`. Everything below ran on 2026-10-30 against the
owner's iPhone 15 (`iPhone15,4`, iOS 26.6.1, Developer Mode on, paired over the CoreDevice network tunnel) unless a line says **unverified**.
Wrap every command that touches Xcode or the phone in `lockf -t 900 /tmp/iris-apple.lock …` (one Apple job at a time on the mini).

```bash
lockf -t 900 /tmp/iris-apple.lock make device          # ran: generate, signed build, install, launch, screenshot -> .artifacts/device-<time>.png
lockf -t 900 /tmp/iris-apple.lock make device-run ARGS="-SomeFlag 1"   # reinstall the last build, launch with arguments, screenshot
lockf -t 900 /tmp/iris-apple.lock make device-screenshot NAME=label    # ran: just the screenshot
xcrun devicectl list devices                           # ran: the phone is `connected`, Reality `physical`; simulators are `simulated`
D=$(. scripts/device-lib.sh; device_id)                # the devicectl identifier, resolved at runtime (never commit it)
xcrun devicectl device process launch --device $D --terminate-existing --console com.jkrumm.iris   # ran; --console shows stdout only, not os.Logger
xcrun devicectl device capture screenshot --device $D --destination out.png   # ran (Xcode 27): the screenshot route
```

- Signing: `DEVICE_SIGNING=personal` (default, free Personal Team) or `paid`; `TEAM=<id>` and `IRIS_DEVICE_ID` override. Team and phone resolve at runtime
  (`scripts/device-lib.sh`). A Personal Team signs without `aps-environment` and the App Group; details, limits and the gated list: AGENTS.md "Device".
  Do not rename bundle ids (10 App IDs per 7 days). Install over the same bundle id keeps the app's data (Keychain, outbox).
- First install: iOS refuses to launch until the developer is trusted on the phone (Settings > General > VPN & Device Management); that is an owner step.
- `pymobiledevice3` **does not work** here: `usbmux list` is empty (the phone is on a network tunnel) and an RSD tunnel needs root. Use `devicectl`.
- Logs: `os.Logger` subsystem `com.jkrumm.iris`; **no headless route** (ran 2026-10-30): `/usr/bin/log collect --device*` says "Must be root to collect logs from attached device" (`log` is a zsh builtin: use the full
  path), `devicectl device sysdiagnose` fails with `DiagnoseError`, `--console` shows stdout only, `pymobiledevice3` has no tunnel. Evidence is screenshots, the take's own transcript and the server memo.
- Screenshots (ran): `make device-screenshot NAME=x` shows the app, the home screen, the Lock Screen with its Live Activity cards and the Dynamic Island, but only while the display is on: a sleeping phone gives a black frame
  (`process launch` fails with `Locked` then). Anything on screen is captured, a call included: look at each frame and delete one with personal content. The owner ends a take before clicking `ask-human` Run, so
  screenshot in a loop while the dialog is open (a new memo in `GET /v1/memos` ~10 s after the start says a take is running) instead of once after the click.
- Read-only phone state (ran): `devicectl device info processes|apps|files|displays`, `device copy from --domain-type appDataContainer --domain-identifier com.jkrumm.iris --source 'Library/Application Support/Iris/outbox.json'`.
  `info lockState` gives only `passcodeRequired` / `unlockedSinceBoot`.
- `GET /v1/memos` lists memos parked at `needs_route` under `pinned`, not `items`: read both.
- Connecting the app: no launch-argument route (no backdoor); the owner types the server URL and the `iphone` device token in Settings > Connection once
  (ran 2026-10-30; a typed memo reached `done`, see the checklist). The tailnet VPN must be on, or Safari shows `NOT_FOUND` and the app "Could not load memos".
  `op://mini/iris/device-tokens` holds every device as `token=device,...`: the owner needs only the part before `=iphone`, which is easy to get wrong and
  was. Cleaner, **unverified**: `ask-human.sh ask '…' --cmd '<read the iphone token on the MacBook | pbcopy>'` and paste on the phone via Universal Clipboard.
  Never print the token, never put it in an `ask-human.sh` message. The Settings "Connected" label only means configured; check reachability with History/Stats loading.
  A memo from the phone shows up in `GET /v1/memos` (skill `memo-debug`); an unreachable server leaves it in the outbox ("Retry in N minutes", Settings).
- The phone must be unlocked for `launch` (`Locked` error otherwise); install works locked.
- `ask-human.sh ask '…' --cmd true --wait N`: exit 0 Run, 1 Deny, 75 unanswered (a timeout is "not run"). It answers `done` in the same second as the push (seen three times on 2026-10-30): a Run/Deny reply is not proof the
  owner did the step. Verify the effect yourself (a launch that works, a screenshot) before relying on it.
- Report each checklist row as pass/fail with the date, device model and iOS version, and append it to the checklist file.
