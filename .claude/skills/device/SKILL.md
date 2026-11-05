---
name: device
description: Put Iris on the paired iPhone — make device (build, sign, install, launch, screenshot), devicectl install and launch, device screenshot, log stream, and the hardware-only checklist. Use when something has to run on real hardware (Lock Screen control, background take, mic switch, Live Activity push).
---

# device

Hardware-only rows live in `docs/spikes/device-checklist.md`; spike briefs in `docs/spikes/`. Everything below ran on 2026-10-30 against the
owner's iPhone 15 (`iPhone15,4`, iOS 26.6.1, Developer Mode on, paired over the CoreDevice network tunnel) unless a line says **unverified**.
Wrap every command that touches Xcode or the phone in `lockf -t 1800 /tmp/iris-apple.lock …` (one Apple job at a time on the mini).

```bash
lockf -t 1800 /tmp/iris-apple.lock make device          # ran: generate, signed build, install, launch, screenshot -> .artifacts/device-<time>.png
lockf -t 1800 /tmp/iris-apple.lock make device-run ARGS="-SomeFlag 1"   # reinstall the last build, launch with arguments, screenshot
lockf -t 1800 /tmp/iris-apple.lock make device-screenshot NAME=label    # ran: just the screenshot
xcrun devicectl list devices                           # ran: the phone is `connected`, Reality `physical`; simulators are `simulated`
D=$(. scripts/device-lib.sh; device_id)                # the devicectl identifier, resolved at runtime (never commit it)
xcrun devicectl device process launch --device $D --terminate-existing --console com.jkrumm.iris   # ran; --console shows stdout only, not os.Logger
xcrun devicectl device capture screenshot --device $D --destination out.png   # ran (Xcode 27): the screenshot route
```

- Signing: `DEVICE_SIGNING=paid` (default; the paid team, headless with the ASC Team key read through `secrets-run`, key file 0600 and deleted on exit) or
  `personal` (fallback: free team, no Push/App Groups; the build drops both keys); `TEAM=<id>` and `IRIS_DEVICE_ID` override. The phone resolves at runtime (`scripts/device-lib.sh`);
  the flags, the key lifecycle and the Personal Team limits: AGENTS.md "Device". Do not rename bundle ids. Install over the same bundle id keeps the app's data (Keychain, outbox).
- APNs proof after `make device` (ran 2026-11-04, paid team, sandbox): the server row `sqlite3 -readonly ~/.iris/data/iris.db "select device,apns_env,apns_token is not null from devices"` shows `iphone|sandbox|1`
  (never print the token); send a typed memo (`IRIS_TOKEN=<iphone token from secrets-run> bun scripts/send-memo.ts --text '…' --mode hermes`) and read `~/Library/Logs/iris.log`: **a delivered push logs nothing**
  (only `notify.apns_rejected|apns_transient|no_token` log), so success is the memo reaching `notified` with none of those lines for its id. A banner needs the notification permission (the app asks once, German "Erlauben")
  and an unlocked, idle phone: a screenshot can show a call or other private content, look before keeping it.
- App Group proof (ran 2026-11-05, paid): `codesign -d --entitlements :- apple/.dd.noindex/Build/Products/Debug-iphoneos/Iris.app[/PlugIns/*.appex] | plutil -convert json -o - -` shows
  `com.apple.security.application-groups: [group.com.jkrumm.iris]` on all three; the app's `widget.container` (`available=true`) and `widget.snapshot` (`saved=true`, `phase`) records in HyperDX
  (`service.name=iris-ios`, `agw otel`) are the container proof; send a typed memo to make the feed write. `devicectl copy from` cannot read `last-memo.json` (container root). A provisioning error
  naming `application-groups` = the group is missing in the portal or on an App ID: owner step (AGENTS.md "Device").
- First install: iOS refuses to launch until the developer is trusted on the phone (Settings > General > VPN & Device Management); that is an owner step.
- `pymobiledevice3` **does not work** here: `usbmux list` is empty (the phone is on a network tunnel) and an RSD tunnel needs root. Use `devicectl`.
- Logs: `os.Logger` subsystem `com.jkrumm.iris`; **no headless route** (ran 2026-10-30): `/usr/bin/log collect --device*` says "Must be root to collect logs from attached device" (`log` is a zsh builtin: use the full
  path), `devicectl device sysdiagnose` fails with `DiagnoseError`, `--console` shows stdout only, `pymobiledevice3` has no tunnel. Evidence is screenshots, the take's own transcript and the server memo.
- Screenshots (ran): `make device-screenshot NAME=x` shows the app, the home screen, the Lock Screen with its Live Activity cards and the Dynamic Island, but only while the display is on: a sleeping phone gives a black frame
  (`process launch` fails with `Locked` then). Anything on screen is captured, a call included: look at each frame and delete one with personal content. The owner ends a take before clicking `ask-human` Run, so
  screenshot in a loop while the dialog is open (a new memo in `GET /v1/memos` ~10 s after the start says a take is running) instead of once after the click.
- Crash reports (ran): `devicectl device info files --device $D --domain-type systemCrashLogs | grep '^Iris-'`, then `devicectl device copy from ... --domain-type systemCrashLogs --source Iris-<time>.ips --destination .artifacts/`;
  the `.ips` is a JSON header line plus a JSON body (`jq`: `.lastExceptionBacktrace`, `.threads[.faultingThread].frames`, `.termination`). Also readable: `capture/quarantine/` and `outbox.json` of the app container.
- Owner steps are German (his phone is German; iOS settings by their German path, `docs/design/feedback-device-1.md` §9). Keep a step short, one action group per dialog. `sips -c` crops from the centre: add `--cropOffset 0 0` for the status bar.
- Read-only phone state (ran): `devicectl device info processes|apps|files|displays`, `device copy from --domain-type appDataContainer --domain-identifier com.jkrumm.iris --source 'Library/Application Support/Iris/outbox.json'`.
  `info lockState` gives only `passcodeRequired` / `unlockedSinceBoot`.
- `GET /v1/memos` returns every memo in `items` (no `pinned`); a memo carries the `kind` Hermes reported and the `actions` it ran. An old parked memo is `failed` at `act`: [Retry from Act] delivers it.
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

## One take's device timeline (unverified until a device take)

The phone has no log access without root (above), so the relay is the log: every capture, route, interruption, outbox, intent and Live Activity
event is also a record in HyperDX (`service.name = iris-ios`, TDD §8). **Unverified:** proven on the simulator only (`-IrisFakeCapture`, records dumped
with `-IrisTelemetryDump <file>`); the first device take (D1) confirms it. Do not ask the owner what he saw until you have read this.

1. Optional, once per round: the owner types a word in Settings > Diagnostics > Run id (German: Einstellungen › Diagnose › Lauf-ID); every record then
   carries `run.id`, so a whole round is one filter.
2. The take's memo id: the newest `GET /v1/memos` item (skill `memo-debug`); the trace id is the same id without the dashes.
3. The timeline, through the `/otel` skill (prod): "logs of `ServiceName:"iris-ios"` with trace id `<id without dashes>`, ordered by the attribute `seq`"; or
   `agw otel "<id without dashes>" --env prod`, or a `clickstack_search` over `ServiceName:"iris-ios"` (add `run.id:<word>` to take every memo of a round).
   Read `event.name`, `seq`, `uptime_ms` (order and durations; the phone clock can step), `app.pid` (a new one mid-take is a relaunch).
4. What to look for: `take.phase` rows (with `source`: who pressed), `capture.session.error` (`call`, `error.fourcc`: `!rec` is "recording not allowed", `!int` "interrupted"),
   `audio.route_change` / `audio.config_change` / `audio.interruption` around a gap in the audio, `capture.gap` (`ms`), `capture.segment.closed` without a later
   `outbox.segment.upload` (data-loss alarm), `liveactivity.snapshot` with `count > 1`, `intent.perform` missing for a press (the extension never reached the app),
   `metrickit.crash|hang` on the launch after a crash, `capture.level` (`rms_db`) against the transcript.
5. Records reach the server at launch, every 10 s and on background; a take killed with the server unreachable shows up at the next launch. No records for a
   whole run: Settings > Connection is not set, or the phone cannot reach the server (the crash file keeps up to 2 000 records).
