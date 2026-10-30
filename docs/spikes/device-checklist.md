# Device checklist (hardware-only)

TDD §9 "Hardware-only". Everything here needs the owner's hands, a paired iPhone (Developer Mode on) and a signed build, so none of it can run
on the mini alone. Run the relevant rows before each R-release and record the result under the row: date, device model, iOS version, pass / fail,
and a note or the finding. Commands for the device side: skill `device`; the server side of a take: skill `memo-debug`.

| # | Check | Pass when | Result |
|-|-|-|-|
| 1 | Lock Screen / Control Center control starts a take (S1) | A Live Activity appears and the timer runs without unlocking, or the documented fallback opens the app and auto-starts | |
| 2 | 30-minute take while switching apps and locking | The memo reaches the server with 180 segments, no gap > 1 s on `GET /v1/memos/:id/audio`, the phone stays within normal battery drain | |
| 3 | Stop from the Live Activity and from the app | The take ends, remaining segments upload, `complete` is sent, the memo reaches `notified` | |
| 4 | Mic switch mid-take: iPhone <-> AirPods (S2) | A segment boundary at the switch, audio continues from the new input, the Live Activity shows the input name | |
| 5 | Built-in mic while connected to the car's Bluetooth (S2) | Records from the built-in mic or the documented limitation is written down | |
| 6 | Phone call interruption | The take pauses at a segment boundary and resumes (iOS 27 `didBecomeInactive` / `resumptionRecommendation`, iOS 26 notification fallback) | |
| 7 | Airplane mode mid-take, then back online | Segments queue in the outbox and upload; `complete` succeeds; nothing is uploaded twice (sha256 idempotence) | |
| 8 | App killed (swipe away) mid-take | At most the last 10 s are lost; the outbox resumes on relaunch | |
| 9 | APNs Live Activity update with the app suspended (S3) | The Live Activity changes phase to done with the headline | |
| 10 | [Play] from the Live Activity or notification with the app suspended (S3) | `/speech` plays, or the app opens (the documented fallback) | |
| 11 | Result notification: banner, actions, content extension | Route chip + headline only, [Play] / [Reply by voice] / [Open] work, no transcript in the payload | |
| 12 | Notification permission flow and token registration | `POST /v1/devices/register` lists the device with `hasApnsToken: true`; sandbox vs production token matches `apnsEnv` | |
| 13 | Dynamic Island and Lock Screen layouts | Compact, expanded and Lock Screen views render, the headline truncates cleanly | |
| 14 | VoiceOver, Dynamic Type XXL, Reduce Transparency | History, Record and the detail stay usable | |
| 15 | Dynamic Island controls: Stop, mic swap, Pause / Resume (Wave 15 I4) | Each button acts with the app in the background: the take stops, the input changes, the phase pauses and resumes, the memo completes without a lost sentence | |
| 16 | Compact take banner while browsing (Wave 15) | The banner shows a running time and Stop over History; the whole banner opens the take screen; Stop ends the take | |
| 17 | Reply flow: keyboard-up composer (Wave 16 I4) | The keyboard icon opens the composer above the keyboard, nothing is clipped, Send posts a reply that appears in the thread | |
| 18 | iOS 26 paths: Liquid Glass with Reduce Transparency, `tabViewBottomAccessory(isEnabled:)` (26.1+), interruption through `interruptionNotification` | Glass surfaces stay legible with Reduce Transparency; the record accessory hides while a take runs (the 26.0 branch cannot run on 26.6.1); the interruption row 6 passes through the 26 notification path | |
| 19 | Background take: segments reach the server while the take runs, app never opened | A memo exists on the server within seconds of the press, with the phone locked | |

Rows 9 to 12 need an `aps-environment` entitlement (Push/APNs), which a Personal Team cannot sign: they are **after enrolment** (S3/D3), not failed. Row 10 also needs `PlayReplyIntent`, which is not built.

Findings that change the design go to the matching spike file and into `docs/TDD.md` §4 / §13.

## Wave 17 D2 run plan (written 2026-10-30; phase 1, nothing run yet)

Device: iPhone 15 (`iPhone15,4`), iOS 26.6.1, Personal Team. Ordered to cost the owner the least: a step is one `ask-human.sh ask '<text>' --cmd true`, a click means "owner says done",
a timeout means not run. **A row passes only on headless proof**; a click alone never does. Exact owner wording and per-step checks: S1 (`D2-1`, `D2-2`, `D2-3`, `D2-9`) and S2 (`D2-6`, `D2-10`) below the Procedure,
the rest here. Install first: `lockf -t 900 /tmp/iris-apple.lock make device` (same team and bundle id, never uninstall, never reset the outbox).

### Toolbox (headless)

| Need | Command | Status |
|-|-|-|
| Look at the phone | `lockf -t 900 /tmp/iris-apple.lock make device-screenshot NAME=d2-<step>` -> `.artifacts/d2-<step>.png` (`Read` it) | ran in D1; on a locked phone **unverified** |
| Locked / unlocked, app alive | `devicectl device info lockState`, `devicectl device info processes` (the Iris process id; a changed id means iOS or the owner killed it) | **unverified** (listed in `devicectl device info --help`) |
| The memo the take made | token: `T=$(secrets-run read op://mini/iris/device-tokens \| tr ',' '\n' \| awk -F= '$2=="iphone"{print $1}')`, never printed; `curl -s -H "Authorization: Bearer $T" http://127.0.0.1:7730/v1/memos?limit=5`; detail has `state`, `segmentCount`, `audioSeconds`, `transcript`, `device` | skill `memo-debug`, ran |
| Audio of a take | `curl -s -H "Authorization: Bearer $T" http://127.0.0.1:7730/v1/memos/<id>/audio -o x.m4a; ffprobe x.m4a` (duration vs wall clock = the gap check) | endpoint exists; the pipeline over a device take ran in D1b |
| `os.Logger` (subsystem `com.jkrumm.iris`) | `devicectl ... --console` shows stdout only. Tried in order, all **unverified**: `/usr/bin/log collect --device-name <name> --last 5m --predicate 'subsystem == "com.jkrumm.iris"' --output .artifacts/d2.logarchive` (`log` is a zsh builtin: use the full path; the phone has no usbmux here, so it may refuse), then `devicectl device sysdiagnose` (heavy). If neither works, logs are not available headless and rows rely on screenshots plus the server |
| The phone's outbox, read-only | `devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier com.jkrumm.iris --source 'Library/Application Support/Iris/outbox.json' --destination .artifacts/d2-outbox.json`: copy out only, nothing is written back | **unverified** |
| Kill the app headless | `devicectl device process terminate --device <id> --pid <pid>` (SIGKILL, same as a swipe-away from the switcher) | **unverified** |

A take the server does not receive: stop at once and report to the lead as a data incident (evidence: `outbox.json` copy, screenshots, the memo list).

### Order

| Step | Owner does | Rows | File |
|-|-|-|-|
| D2-0 | One-time prep: phone unlocked, Tailscale VPN on, Settings > Battery > Battery Percentage on, add the Iris control to the Lock Screen and to Control Center, Live Activities allowed for Iris, microphone allowed, AirPods charged | all | here |
| D2-1 | Lock Screen start, island compact / expanded, Pause / Resume, mic swap, Stop from the island (one take, ~1 min) | 1, 13, 15, 19 | S1 |
| D2-2 | Control Center start, lock, Stop on the Lock Screen card (~20 s) | 1, 3 | S1 |
| D2-3 | Siri "Record with Iris", browse to History for the banner, Stop in the app (~30 s) | 1, 3, 16 | S1 |
| D2-4 | Open the memo of D2-3, tap the keyboard icon in the reply bar, type "ok", Send | 17 | here |
| D2-5 | Reduce Transparency + largest Dynamic Type, then VoiceOver; look at Record, History, the detail; set it all back | 14, 18 | here |
| D2-6 | AirPods in / out mid-take, forced built-in, back (~2 min) | 4 | S2 |
| D2-7 | Phone call (or Siri) interrupts a take | 6, 18 | here |
| D2-8 | Start a take; I kill the app headless; relaunch | 8 | here |
| D2-9 | The 30-minute take with an Airplane Mode window | 2, 7, 19 | S1 |
| D2-10 | The car (separate session) | 5 | S2 |

**D2-4: keyboard-up composer.** Owner: "Open the newest memo (the Siri one), tap the keyboard icon in the bottom bar, type *ok*, do not send yet." I screenshot `d2-4-keyboard` (the composer sits above the keyboard, nothing clipped,
send button visible); then owner: "Send." The reply appears in `GET /v1/memos` as a typed memo with the thread id of the first. Pass: the screenshot and the reply on the server.

**D2-5: accessibility and Liquid Glass.** Owner: "Settings > Accessibility > Display & Text Size: Reduce Transparency on, Larger Text on at the largest size. Open Iris: Record, then History, then a memo detail."
I screenshot each (`d2-5-record`, `-history`, `-detail`): glass surfaces (tab accessory, take banner, route chips, reply bar) stay legible, text neither clips nor overlaps. Then owner: "Turn on VoiceOver (triple-click the side button), swipe through
History and open a memo", `devicectl device info voiceover` confirms it is on (**unverified**), screenshot with the focus ring; the spoken labels are the owner's call (Run = usable, Deny = not). Last step, always:
"Turn VoiceOver, Reduce Transparency and Larger Text back off." Pass: all three screens usable at each setting. The 26.0 `tabViewBottomAccessory` branch cannot run on 26.6.1: noted, not failed.

**D2-7: interruption.** Owner: "Start a take. Say *Before the call.* Call this phone from another phone or the Mac, let it ring 5 s, answer, hang up after 5 s. Then say *After the call.* Stop." Screenshot `d2-7-call` during the call
(the call UI). If no second phone: hold the side button for Siri, say "what time is it", wait for the answer (that is the same interruption). Headless after the stop: memo `done`; the transcript holds "Before the call" and "After the call"
(resumed); `segmentCount` > `audioSeconds / 10` (an interruption rolls a segment); the phase `paused` is visible only if a screenshot catches the island/card, otherwise noted. On iOS 26 the code runs
`AVAudioSession.interruptionNotification` (the iOS 27 `didBecomeInactive` pair is the other branch): this row is the only device proof of the 26 branch. Pass: resumes without the owner touching the phone beyond the call.

**D2-8: kill mid-take.** Owner: "Start a take with the record button, say *Kill test*, and leave the phone unlocked on the take screen." I wait 25 s, read the Iris pid (`info processes`), kill it headless, relaunch with `devicectl device process launch` (phone unlocked),
screenshot `d2-8-relaunch`. Headless: the memo reaches `done` after the outbox resumes; `segmentCount` is at least floor(25/10) = 2 (at most the last 10 s lost); the transcript holds "Kill test"; the orphaned Live Activity is gone after launch.
Pass: the memo completes from the relaunch alone. A memo that stays `receiving` is a data incident.

### Per-row result

Filled in phase 2: each row is `pass` / `fail` / `after enrolment`, with date, device, iOS and the evidence file names under `.artifacts/` (untracked).

## Wave 17 D1: bring-up (2026-10-30, iPhone 15 `iPhone15,4`, iOS 26.6.1, Personal Team)

- `make device`: build, sign, install, launch, screenshot: pass. Screenshot via `xcrun devicectl device capture screenshot`; `pymobiledevice3` unusable (no usbmux, tunnel needs root).
- First launch refused until the developer was trusted on the phone (owner step, once).
- Production composition over the tailnet: pass. A typed memo ("Device test: hello from the iPhone") typed on the phone reached `done` (`notified`, route `hermes`,
  `typed: true`, device `iphone`, steps route/act/summarize/notify done): memo `3418749a-6422-46da-84df-2d5b0bf19631`, confirmed with `GET /v1/memos/:id`.
- What it took: the Tailscale VPN on the phone (it was off: Brave showed `NOT_FOUND`, the app "Could not load memos"), then re-entering the token
  (the first entry did not authenticate). Findings for the app: Settings shows "Connected" with a saved but unreachable or rejected configuration (it means
  "configured", not "reachable"); entering the token is error-prone because `op://mini/iris/device-tokens` holds all devices as `token=device` pairs.

## Wave 17 D1b: the first device take (2026-10-30, iPhone 15, iOS 26.6.1)

- A take recorded while the phone was offline created its memo when the
  tailnet came up but never sent a segment. The saved queue named the three segment files by absolute container path, an install over the app
  had moved the container, and every upload failed as "the recording file is gone" (permanent, so stalled) with the audio intact in the new
  container. Fixed by saving file names and resolving them against the current capture directory; row 7 and 8 (airplane mode, kill) must
  also pass **across an install of a new build** over the same bundle id. The take was delivered by hand from a copy of the container.
- Verified on the phone with the fixed build installed over the old one (same bundle id and team, container kept): the three stalled segments of the
  first take were sent from the current capture directory, the server answered 409 `bad_state` (the memo had been completed by hand) and
  `segmentCount` 3 covered them, `complete` cleared the take, and `outbox.json` ended with no entries, items or memos and the memo in
  `completedMemos`. Pass.
