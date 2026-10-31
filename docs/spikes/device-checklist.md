# Device checklist (hardware-only)

TDD §9 "Hardware-only". Everything here needs the owner's hands, a paired iPhone (Developer Mode on) and a signed build, so none of it can run
on the mini alone. Run the relevant rows before each R-release and record the result under the row: date, device model, iOS version, pass / fail,
and a note or the finding. Commands for the device side: skill `device`; the server side of a take: skill `memo-debug`.

| # | Check | Pass when | Result |
|-|-|-|-|
| 1 | Lock Screen / Control Center control starts a take (S1) | A Live Activity appears and the timer runs without unlocking, or the documented fallback opens the app and auto-starts | **fail** (2026-10-30, iPhone 15, iOS 26.6.1): the Record control does nothing, locked or unlocked, and Siri has no phrase; in-app start works. Fix in I8. `d2-1-cc-press.png`, S1 findings <br>**Re-test 2026-10-30 21:50 (build `459a517`, iPhone 15, iOS 26.6.1): partial.** Control Center: the control now starts a take and opens the app (memo `a66fc402`, 37.6 s, 4 segments): pass through the documented fallback. Lock Screen: **fail**, pressing the control does nothing (the owner has to unlock to press it, so "without unlocking" cannot be met; the platform rule is that Lock Screen buttons are inactive until unlock, see the Wave 18 D1 section). <br>**Wave 18 I7: fix built, device re-test pending** (steps: "Wave 18 I7" at the end of this file). |
| 2 | 30-minute take while switching apps and locking | The memo reaches the server with 180 segments, no gap > 1 s on `GET /v1/memos/:id/audio`, the phone stays within normal battery drain | **pass** (2026-10-30, iPhone 15, iOS 26.6.1, memo `53745cb2`): started in the app (the control does not start), locked, apps switched, 30 min: 183 segments, 1856 s of audio (encoder priming adds ~0.14 s per segment), no silence >= 1 s, Iris pid constant (iOS did not kill it), battery about 69 % -> 65 % (4 pp) |
| 3 | Stop from the Live Activity and from the app | The take ends, remaining segments upload, `complete` is sent, the memo reaches `notified` | **pass** (2026-10-30, iPhone 15, iOS 26.6.1): Stop from the Lock Screen card ends the take (memo `14427935`: 28.7 s, 3 segments, `complete` within a second, the take survived the lock), Stop from the island (`1444a1bd`: 24.9 s, 3 segments), Stop from the app and the banner (`ddaad4d8`) |
| 4 | Mic switch mid-take: iPhone <-> AirPods (S2) | A segment boundary at the switch, audio continues from the new input, the Live Activity shows the input name | **fail** (2026-10-30, iPhone 15, iOS 26.6.1): connecting AirPods mid-take does not switch the input (the chip stays on the phone microphone); picking the AirPods in the mic sheet crashed the app (SIGABRT, memo `0cbda45f`: 34.1 s up to the crash, nothing after; `Iris-2026-10-30-142452.ips`). A take started with the AirPods already connected picked them (chip <AirPods name>, `d2-8b-prekill.png`). Fix in I7 <br>**Re-test 2026-10-30 21:55: pass** (memo `d1f19d64`, 88.8 s, 13 segments, `notified`): AirPods connected, switched iPhone to AirPods in the app, then swapped in the island; no crash (no new `Iris-*.ips` after the install), the transcript is continuous across both switches. The island swap lagged: the first press looked like nothing, then it switched. |
| 5 | Built-in mic while connected to the car's Bluetooth (S2) | Records from the built-in mic or the documented limitation is written down | **not run** (needs the car; S2 stays open) |
| 6 | Phone call interruption | The take pauses at a segment boundary and resumes (iOS 27 `didBecomeInactive` / `resumptionRecommendation`, iOS 26 notification fallback) | **pass** (2026-10-30, iPhone 15, iOS 26.6.1): Siri held mid-take; the take kept recording, no error text, transcript holds the phrases before and after (memo `8208eaeb`, 46.9 s, 5 segments). This is the iOS 26 `interruptionNotification` branch |
| 7 | Airplane mode mid-take, then back online | Segments queue in the outbox and upload; `complete` succeeds; nothing is uploaded twice (sha256 idempotence) | **pass** (2026-10-30, iPhone 15, iOS 26.6.1): Airplane Mode 13:55 to 13:57Z inside the 30-minute take: the phone dropped off the tunnel, the memo stayed `receiving`, after the tailnet returned the segments went up and `complete` succeeded with exactly 183 segments, nothing duplicated |
| 8 | App killed (swipe away) mid-take | At most the last 10 s are lost; the outbox resumes on relaunch | **pass** (2026-10-30, iPhone 15, iOS 26.6.1): app killed 34 s into a take (`devicectl device process terminate`, memo `607e6a51`): the memo completed after the owner reopened Iris, 3 segments / 30.4 s, so only the open segment (about 4 s) was lost; the outbox is empty, nothing duplicated. The open segment sits in `capture/quarantine/` as an unfinalised m4a (no `moov` atom, unreadable by ffprobe), see S1 findings |
| 8a | Force-quit mid-segment (Wave 18 I2) | App switcher swipe-up while a take is recording, 3–8 s into a segment; relaunch: the memo reaches `notified` and its transcript holds the last words spoken before the kill (all but about a second); nothing in `capture/quarantine/` | **open** (owner): the segment written when the app dies is a fragmented m4a, the startup sweep adopts it as the take's next segment. Headless check: `capture sweep: 1 adopted` in the launch log and `outbox.complete.sent` with `segmentCount` one above the segments uploaded before the kill |
| 9 | APNs Live Activity update with the app suspended (S3) | The Live Activity changes phase to done with the headline | **after enrolment** (needs `aps-environment`) |
| 10 | [Play] from the Live Activity or notification with the app suspended (S3) | `/speech` plays, or the app opens (the documented fallback) | **after enrolment**; `PlayReplyIntent` is also not built |
| 11 | Result notification: banner, actions, content extension | Route chip + headline only, [Play] / [Reply by voice] / [Open] work, no transcript in the payload | **after enrolment** (the result notification is an APNs alert) |
| 12 | Notification permission flow and token registration | `POST /v1/devices/register` lists the device with `hasApnsToken: true`; sandbox vs production token matches `apnsEnv` | **after enrolment** (no `aps-environment`, so no APNs token) |
| 13 | Dynamic Island and Lock Screen layouts | Compact, expanded and Lock Screen views render, the headline truncates cleanly | **pass** (2026-10-30, iPhone 15, iOS 26.6.1): compact island (waveform glyph, timer, orange mic dot) `d2-1-take-02.png`; expanded island Paused / Processing cards `d2-1-island-03.png`, `d2-1-take-03.png`; Lock Screen Recording card (timer, `Auto`, input name, Stop / mic swap / Pause) and Processing cards `d2-1-take-07.png`. Headline truncation not seen (no headline without APNs) |
| 14 | VoiceOver, Dynamic Type XXL, Reduce Transparency | History, Record and the detail stay usable | **dropped by the owner** (`docs/design/feedback-device-1.md` §7: text sizes are out of scope); Reduce Transparency and large text were looked at once, Settings stayed readable (`d2-5-a11y-05.png`) |
| 15 | Dynamic Island controls: Stop, mic swap, Pause / Resume (Wave 15 I4) | Each button acts with the app in the background: the take stops, the input changes, the phase pauses and resumes, the memo completes without a lost sentence | **fail** (2026-10-30, iPhone 15, iOS 26.6.1): Pause works (`d2-1-island-03.png`), Stop works (memo `1444a1bd`), Resume does not ("engine resume failed", memo `1c193eab`, 18.3 s). Mic swap in the island not tried: switching the input crashes the app (row 4). Fix in I7 <br>**Re-test 2026-10-30 21:50: still fail.** Pause works, Resume fails again ("The recorder stopped. Engine resume failed.", the UI timer keeps counting; memo `cd6f0e19`, 14.6 s, 2 segments, the transcript ends at the Pause). Stop on the Live Activity card works (`5595f89f`, 9.1 s). Island mic swap works (row 4). <br>**Wave 18 I7: fix built, device re-test pending** (steps: "Wave 18 I7" at the end of this file). |
| 16 | Compact take banner while browsing (Wave 15) | The banner shows a running time and Stop over History; the whole banner opens the take screen; Stop ends the take | **pass** (2026-10-30, iPhone 15, iOS 26.6.1): compact banner over History with red dot, `0:16 Auto · iPhone-Mikrofon` and Stop, tapping Stop ends the take; the Record accessory is hidden while it runs `d2-3-banner-05.png` |
| 17 | Reply flow: keyboard-up composer (Wave 16 I4) | The keyboard icon opens the composer above the keyboard, nothing is clipped, Send posts a reply that appears in the thread | **pass** for the New memo composer (2026-10-30, iPhone 15, iOS 26.6.1): Cancel, title, Send, mode chips, text, count and hint sit above the keyboard, nothing clipped (`d2-4-keyboard.png`; a call's picture-in-picture window covers part of the hint, the system's). The thread reply bar's keyboard icon was not captured |
| 18 | iOS 26 paths: Liquid Glass with Reduce Transparency, `tabViewBottomAccessory(isEnabled:)` (26.1+), interruption through `interruptionNotification` | Glass surfaces stay legible with Reduce Transparency; the record accessory hides while a take runs (the 26.0 branch cannot run on 26.6.1); the interruption row 6 passes through the 26 notification path | **partial**: `tabViewBottomAccessory(isEnabled:)` hides the Record accessory while a take runs (26.6.1, `d2-3-banner-05.png`); the interruption branch passes (row 6); Reduce Transparency was dropped by the owner; the 26.0 branch cannot run on 26.6.1 |
| 19 | Background take: segments reach the server while the take runs, app never opened | A memo exists on the server within seconds of the press, with the phone locked | **pass** for an in-app start (2026-10-30, iPhone 15, iOS 26.6.1): the memo exists on the server 11 s after the press with the app in the background (`8cffd169`, 5 segments); not provable from the control, which does not start a take |
| 20 | A Live Activity does not outlive its take without APNs (Wave 17 D2) | After the hand-over a finished take's activity ends or reads done; the island always shows the running take | **fail** (2026-10-30, iPhone 15, iOS 26.6.1): every finished take left a "Processing" card counting up for hours and the island showed it instead of the running take (`d2-1-take-07.png`, `-02.png`). Fix in I8 <br>**Re-test 2026-10-30 21:50: still fail.** After Stop on the card the activity switches to "Iris working on it" and stays: the counter keeps running after the memo is done, and the owner counted two such cards (memos `a66fc402`, `5595f89f`). No screenshot (the Apple slot was held by other jobs, see below). <br>**Wave 18 I7: fix built, device re-test pending** (steps: "Wave 18 I7" at the end of this file). |
| 21 | The recorder survives a lock and an island Pause / Resume (Wave 17 D2) | The take keeps recording, or says it stopped where the user looks | **fail** (2026-10-30, iPhone 15, iOS 26.6.1): the recorder died four ways: (a) "engine resume failed" after an island Resume and in one lock case, the UI kept counting (memos `1c193eab` 18 s, `8cffd169` 41 s); (b) an uncaught `NSException` from `AVAudioNode installTapOnBus` inside `handleConfigurationChange()` aborted the app twice, on picking the AirPods mid-take (14:24) and on tapping Record with the AirPods connected (14:39, no memo: the take died before its first segment closed) (`Iris-2026-10-30-142452.ips`, `-143927.ips`); (c) a take stopped itself after 10 s (memo `8ba6239b`, 1 segment); (d) a 0x8BADF00D scene-update watchdog kill when stopping from the banner (`-135713.ips`). Fix in I7 <br>**Re-test 2026-10-30 21:50: still fail** for the island Resume (row 15). The lock-for-20-seconds step was not reached because the take died at Resume. No crash report since the install. <br>**Wave 18 I7: fix built, device re-test pending** (steps: "Wave 18 I7" at the end of this file). |

Rows 9 to 12 need an `aps-environment` entitlement (Push/APNs), which a Personal Team cannot sign: they are **after enrolment** (S3/D3), not failed. Row 10 also needs `PlayReplyIntent`, which is not built.

Findings that change the design go to the matching spike file and into `docs/TDD.md` §4 / §13.


**Also re-tested 2026-10-30 (Wave 18 D1, build `459a517`):** Stop from the History banner **pass** (memo `3fefefed`, 14.0 s, 2 segments, `notified`, no watchdog kill, no new crash report; closes the 0x8BADF00D finding of row 21(d)). The level meter while speaking: owner says it reacts, small when quiet and large when loud, maybe a little large (memo `8db2a05a`, 30.7 s); in an earlier take he thought the bars could move faster. History scroll jump: **not run** (devicectl has no screen recording; left to the Wave 18 I5 simulator pass). Copy into Notes: not run.

## Wave 17 D2 run plan and status (2026-10-30)

Device: iPhone 15 (`iPhone15,4`), iOS 26.6.1, Personal Team. Ordered to cost the owner the least: a step is one `ask-human.sh ask '<text>' --cmd true`, a click means "owner says done",
a timeout means not run. **A row passes only on headless proof**; a click alone never does. Exact owner wording and per-step checks: S1 (`D2-1`, `D2-2`, `D2-3`, `D2-9`) and S2 (`D2-6`, `D2-10`) below the Procedure,
the rest here. Install first: `lockf -t 900 /tmp/iris-apple.lock make device` (same team and bundle id, never uninstall, never reset the outbox).

**Status:** everything ran except the car (D2-10) and the reply bar's keyboard icon. D2-2 failed at its first press (the control does nothing), D2-5 was dropped by the owner (text sizes are out of scope), D2-6 crashed the app. The owner steps
were rewritten in German after the first hour (`docs/design/feedback-device-1.md` §9). What each step showed is in the Result column and the S1/S2 findings.
Lessons for the next run: the owner stops a take before clicking Run, so a screenshot taken after the click misses it: run a watcher that screenshots every few seconds from the moment a new memo appears
(`GET /v1/memos` shows it ~10 s after the start) while the dialog is open, and have the owner narrate each press aloud (the transcript then carries the order of events and the app's reaction). `GET /v1/memos` puts memos parked at
`needs_route` in a separate `pinned` array, not in `items`.

### Toolbox (headless)

| Need | Command | Status |
|-|-|-|
| Look at the phone | `lockf -t 900 /tmp/iris-apple.lock make device-screenshot NAME=d2-<step>` -> `.artifacts/d2-<step>.png` (`Read` it) | ran in D1 and D2; shows the Lock Screen, the Live Activity card and the island too, but only with the display on: a sleeping or call-covered phone gives a black frame or someone's call screen (delete such a frame) |
| Locked / unlocked, app alive | `devicectl device info lockState`, `devicectl device info processes` (the Iris process id; a changed id means iOS or the owner killed it) | ran: `lockState` shows only `passcodeRequired`/`unlockedSinceBoot` (a locked phone is told by `process launch` failing with `Locked`), `processes` lists the app and its widget extension pid |
| The memo the take made | token: `T=$(secrets-run read op://mini/iris/device-tokens \| tr ',' '\n' \| awk -F= '$2=="iphone"{print $1}')`, never printed; `curl -s -H "Authorization: Bearer $T" http://127.0.0.1:7730/v1/memos?limit=5`; detail has `state`, `segmentCount`, `audioSeconds`, `transcript`, `device` | skill `memo-debug`, ran |
| Audio of a take | `curl -s -H "Authorization: Bearer $T" http://127.0.0.1:7730/v1/memos/<id>/audio -o x.m4a; ffprobe x.m4a` (duration vs wall clock = the gap check) | endpoint exists; the pipeline over a device take ran in D1b |
| `os.Logger` (subsystem `com.jkrumm.iris`) | `devicectl ... --console` shows stdout only. Ran 2026-10-30, **both fail**: `/usr/bin/log collect --device-name <name> --last 5m --output .artifacts/d2.logarchive` (`log` is a zsh builtin: use the full path) says "Must be root to collect logs from attached device"; `devicectl device sysdiagnose` ends in `CoreDeviceCLISupport.DiagnoseError`. No headless log route: rows rely on screenshots, the take's own transcript and the server | ran, fails |
| The phone's outbox, read-only | `devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier com.jkrumm.iris --source 'Library/Application Support/Iris/outbox.json' --destination .artifacts/d2-outbox.json`: copy out only, nothing is written back (also `devicectl device info files` to list the container) | ran |
| Kill the app headless | `devicectl device process terminate --device <id> --pid <pid>` (SIGKILL, same as a swipe-away from the switcher) | **unverified** (D2-8 not run) |

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

## Wave 17 I7: a take across a lock-time interruption (2026-10-30, iPhone 15, iOS 26.6.1)

- Finding (owner device, memo `8cffd169…`): the take screen showed 1:04 and "The recorder stopped: engine resume failed"; the server held
  41.4 s in 5 segments. The missing ~23 s are the interruption window itself (the engine is paused while the session is interrupted), not audio
  lost after capture: the phone's container held no leftover segment file, and `outbox.json` lists the memo in `completedMemos`. The resume
  called `engine.start()` without reactivating the session, so it failed and the take was parked as `failed`. A 45 s locked take that met no
  interruption was fine. Whether the system interrupted the session, and why, is not known from the logs we have (unverified).
- Fix (fakes only): reactivate the session before the resume, rebuild the engine when it will not restart, rebuild after a media-services reset,
  finish a failed take at once.
- To verify on the phone (pending, owner step): start a take, lock the phone for 90 s while speaking numbered sentences, unlock, stop. Pass:
  every sentence is in the transcript, or the screen says the take ended early and the transcript holds everything before that.

## Wave 18 D1: device re-test of the Wave 17 fixes (2026-10-30 evening, iPhone 15, iOS 26.6.1, build `459a517`)

Master installed with `make device` over the app (same bundle id, outbox untouched). Owner steps in German, batched by group after the first screens were too slow; every row below is checked against the server memo, never against a click (`ask-human` answers in the same second as the push).

| Row | Result | Evidence |
|-|-|-|
| 1 Lock Screen | **fail**, nothing happens | owner narration in memo `a66fc402` |
| 1 Control Center | **pass** (fallback: the app opens and records) | `a66fc402`, 4 segments |
| 4 AirPods switch | **pass** | `d1f19d64`, 13 segments, no crash report |
| 15 island controls | **fail**: Resume | `cd6f0e19` (Pause pass, Stop pass `5595f89f`, mic swap pass) |
| 20 stale Processing activity | **fail** | owner narration in `a66fc402`, `5595f89f` |
| 21 lock + island pause/resume | **fail** (Resume), lock step not reached | `cd6f0e19` |
| History banner Stop (I9) | **pass** | `3fefefed`, no crash report |
| Level meter while speaking | owner: reacts well (subjective, no headless proof) | `8db2a05a` |
| History scroll jump (I10) | **not run** | no headless screen recording |
| Copy a reply into Notes (Wave 17 I5) | **not run** | |
| `ddaad4d8` tail recovery | **lost** (Wave 18 I7), see below | `.artifacts/recovery/` |

**`ddaad4d8` tail.** Copied from the phone's `capture/quarantine/` (the phone copy stays): 60 355 bytes, `ftyp`, then 24 KiB of zeros where the `mdat` header and a `free` atom would be, then 35 778 bytes of raw AAC frames (about 235 to 250 bytes each, variable); `ffprobe`: "moov atom not found". Neither `untrunc` nor `MP4Box` is installed, and the frame boundaries cannot be recovered without a sample table, so no stock tool delivers it. About 9 s of audio is in it. **Marked lost (Wave 18 I7):** an unfinalised m4a with no `moov` and no sample table, which no installed tool reads; no raw-AAC frame parser was written (the frame boundaries are variable and the 24 KiB of zeros hide where the stream starts). The phone copy stays in `capture/quarantine/`. Product fix: a crash-safe working container (below).

**Why the Lock Screen control does nothing (research, `agw research --depth deep`, partial: 11 of the run's citations were dropped as unretrieved, so treat details as leads).** Apple: "On a locked device, buttons and toggles are inactive and the system doesn't perform actions unless a person authenticates and unlocks their device" (WidgetKit, "Adding interactivity to widgets and Live Activities"). So the Lock Screen press needs an unlock first; the owner reports the press after unlocking still does nothing. A plain `AppIntent` control runs in the widget extension, which cannot record (QA1872); `LiveActivityIntent` runs in the app process. The Control Center path that now works is consistent with that.

**Why Resume fails.** Resuming after an interruption needs `setActive(true)` again; started from the background the session activation or `engine.start()` fails with `cannotStartRecording` (`!rec`, 561145187), `cannotInterruptOthers` (`!int`, 560557684) or `cannotStartPlaying` (`!pla`, 561015905). Apple DTS: `!rec` "usually happens when trying to start a recording while the app is in the background". Only a user-initiated system surface (`AudioRecordingIntent` plus a Live Activity started first and kept active) grants the start; whether that holds from a locked or backgrounded state on iOS 26 is not documented, and one field report shows `!pla` on the Lock Screen. This is a hypothesis for our failure: no log shows the code.

**Rebuild sequence that avoids the `installTapOnBus` crash.** On `AVAudioEngineConfigurationChange` Apple states the engine stops, uninitializes and keeps the nodes connected with the old formats; the app must re-establish connections. Debounce triggers, stop, remove the tap, reconnect, re-read `inputNode.outputFormat(forBus: 0)`, refuse a zero sample rate or channel count, re-create the converter, install the tap, `prepare`, `start`, and begin a new segment. The row 4 pass shows the I7 guard works for the AirPods switch.

**Stale Live Activities.** Apple prescribes the reconciliation: on launch end every activity that is no longer relevant (`Activity.activities`, `end(_:dismissalPolicy: .immediate)`), end it inside the background task that finishes the take, set `staleDate` on every update. A `staleDate` marks it stale, it does not end it. Updates from the background are best effort (a field report: about 30 s).

**Crash-safe segments.** `AVAudioFile` writes the container index on close ("only necessary to close a file opened for writing in order to achieve specific control over when the file's header is updated"), so a kill leaves an m4a without `moov`. Options: CAF (an unknown-size data chunk is recoverable to EOF), fragmented MP4 through `AVAssetWriter.movieFragmentInterval`, or an explicit `close()` at every segment end (cheapest). Wave 18 I2 took the fragmented MP4: a SIGKILL experiment kept all but ~0.5 s (`docs/research/2026-10-30-avaudiofile-kill.md`).

**What device logging was missing (input for Wave 18 I6).** There is no log from the phone at all. `log collect` needs root, `devicectl device sysdiagnose` fails, `--console` shows stdout only, and the `IrisTelemetry` package (tested, linked in `apple/project.yml`) is imported by no app source file, so HyperDX holds no `iris-ios` spans or logs (queried 2026-10-30, the last four hours: only `iris-server`). No MetricKit subscriber either. The next round needs these fields, one structured record per event, relayed through `POST /v1/telemetry`:
- every route change and configuration change: notification name, `AVAudioSessionRouteChangeReasonKey`, previous and current route (port type, name, uid), session sample rate and IO buffer duration, `inputNode.outputFormat(forBus: 0)` before and after (sample rate, channel count), `engine.isRunning`, the tap format that was installed, a restart generation id
- every `setActive` or `engine.start()` failure: `NSError` domain, code and the four-character code (`561145187 (!rec)`), which call failed, application state and scene phase, `IntentSystemContext.currentMode`, whether a Live Activity was active
- interruptions: type, options (`shouldResume`), reason; frames of audio missing between the last buffer and the resumed one
- Live Activity: activity id, `activityState` at each transition, `staleDate`, `ActivityAuthorizationError` on a failed request, dismissal policy used
- file: segment index, bytes written, whether `close()` ran
- plus MetricKit crash and hang payloads on the next launch
Without these, a device round shows only that a row fails, never why. Wave 17 D2 and this re-test both ended there.

**Process notes.** The Apple slot was held by other sessions for long stretches (a `check-apple` and `uitest` runs for 15 minutes and more, a 30-minute `xcodebuild` job), so live screenshots during takes never ran; a screenshot is one `lockf` hold and starved. Wave 18 I5 screens: three dark History screens (top, scrolled, search) are in `.artifacts/device-i5/`; the rest was left to the simulator pass at the lead's request. No light-mode device shots (no headless appearance switch).

## Mac hands-on rows (Wave 18 M2, owner's MacBook)

What the mini proved: the panel, the model and the take path on fakes (`IrisMacTests`, `IrisCaptureTests`), screenshots of the real floating panel and of the
refused-microphone message (`IrisMac -IrisFakeData -IrisMacPanelWindow -IrisMacSnapshot <dir>`: `recording.png`, `recording-refused.png`, `settings.png`). What it
cannot prove: the microphone prompt, a real hotkey press, a real take. The mini has no microphone and nobody to answer a TCC prompt.

**Signing (why it matters).** macOS keys the microphone grant to the code signature. An ad-hoc or unsigned build gets a new identity on every build, so Iris would
ask again after each rebuild (`tccutil reset Microphone com.jkrumm.iris.mac` clears a stuck grant). CI and `make check-apple` build unsigned (`CODE_SIGNING_ALLOWED=NO`) and
never record. A build signed with a stable Apple Development identity keeps its grant.

- **The mini can** build and sign `IrisMac` with its Apple Development identity (hardened runtime, sandbox, audio input; `codesign --verify --strict` passes; checked
  2026-10-31) without a provisioning profile, provided the build drops the `com.apple.security.application-groups` entitlement (the Mac reads no App Group). Recipe, from `apple/`
  after `make generate`: write a copy of `IrisMac/IrisMac.entitlements` without the `application-groups` key and build with
  `xcodebuild build -scheme IrisMac -destination 'platform=macOS,arch=arm64' CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=<sha1 from security find-identity -v -p codesigning> CODE_SIGN_ENTITLEMENTS=<that copy>`.
  Not done on the mini and not needed for the rows: `-allowProvisioningUpdates` with `DEVELOPMENT_TEAM` would register the `com.jkrumm.iris.mac` App ID, and a Personal Team has 10 App IDs per 7 days
  (the iPhone targets use three).
- **The mini cannot** show the microphone prompt, grant it, or press a key for the Mac: TCC prompts need a person at a screen, and the mini has no input device.
- **On the MacBook** the same recipe works with the MacBook's own Apple Development identity (`security find-identity -v -p codesigning`), run from a checkout of this
  branch. Build it once, keep that app in `~/Applications`, and rebuild with the same identity: the grant stays. Iris is a menu-bar app (`LSUIElement`): the icon is a waveform in the menu bar.

| # | Check (German steps) | Pass when | Result |
|-|-|-|-|
| M1 | **Mikrofon-Berechtigung.** Iris starten. Zuerst im Menüleistensymbol (Wellenform) auf das Zahnrad klicken, Server-URL und Token eintragen, „Save". Dann in einer anderen App (TextEdit) **Control-Option-M** drücken. | Systemdialog „„Iris" möchte auf das Mikrofon zugreifen" erscheint. Nach „Erlauben" erscheint oben mittig ein schwebendes Panel: roter Punkt, Zeit läuft, Pegelbalken bewegen sich beim Sprechen. | |
| M2 | **Grant bleibt nach Rebuild.** Panel mit Control-Option-M beenden. Iris beenden, mit derselben Signatur neu bauen und starten, wieder Control-Option-M. | Kein zweiter Berechtigungsdialog, die Aufnahme startet sofort. (Mit ad-hoc Signatur käme der Dialog erneut: das ist der Grund für die stabile Signatur.) | |
| M3 | **Verweigert.** Systemeinstellungen › Datenschutz & Sicherheit › Mikrofon › Iris ausschalten. Control-Option-M. | Das Panel zeigt „Iris may not use the microphone …" mit „Open Settings" und „Close"; „Open Settings" öffnet genau diese Systemeinstellung. Danach Schalter wieder an: Control-Option-M startet. | |
| M4 | **Fokus bleibt.** In TextEdit tippen, Control-Option-M drücken, weitertippen. | Das Panel nimmt den Fokus nicht: der Cursor in TextEdit bleibt aktiv, die Buchstaben landen weiter in TextEdit, das Panel steht vor TextEdit. | |
| M5 | **Stoppen und Ankommen.** Etwa 25 Sekunden sprechen („Notiz: Test vom Mac"), Control-Option-M drücken. Menüleistensymbol anklicken. | Das Panel verschwindet, ohne Neuladen steht das Memo oben in der History und läuft bis „Done" durch (Modus Auto, drei Segmente). In der Mac-Benachrichtigung steht Route und Überschrift, kein Transkript. | |
| M6 | **Popover offen.** Menüleistensymbol anklicken (Popover offen lassen), Control-Option-M. | Genau ein Take startet (nicht zwei, nicht keiner); Stop über Control-Option-M klappt auch bei offenem Popover (offene Fehler 243/244 von KeyboardShortcuts). | |
| M7 | **Taste ändern.** Menüleistensymbol › Zahnrad › „Recording" › auf das Feld neben „Start / stop key" klicken, Control-Option-R drücken. | Control-Option-M tut nichts mehr, Control-Option-R startet/stoppt. Mit dem ✕ im Feld löschen: Hinweis „This key is not active …"; Control-Option-M erneut aufnehmen stellt den Standard wieder her. | |
| M8 | **Belegte Taste.** Im Feld eine Kombination aufnehmen, die eine andere App schon global belegt (z. B. die von Raycast oder Alfred). | Der Recorder warnt vor Systemtasten; bei einer Taste einer fremden App erscheint „This key is not active …" (die Registrierung scheitert still). | |
| M9 | **Diktat unberührt.** Fn-Diktat (doppelt Fn) in einer Textapp benutzen. | Diktat funktioniert wie vorher; Control-Option-M löst kein Diktat aus. | |
| M10 | **Mikrofon wechseln.** Zweites Mikrofon anschließen (AirPods oder USB). Take starten, im Panel das Mikrofon-Menü öffnen und es wählen. | Das Menü listet beide Geräte; nach der Wahl läuft die Aufnahme weiter (Transkript durchgehend, ein Segmentwechsel am Wechsel). Nach dem Stop steht in Systemeinstellungen › Ton › Eingabe wieder das vorherige Gerät. | |
| M11 | **Abbrechen.** Take starten, 5 Sekunden sprechen, im Panel „Cancel". | Das Panel verschwindet, nach einer Minute taucht kein Memo in der History auf; die Eingabe ist wieder die alte. | |
| M12 | **Offline.** WLAN/Tailscale aus, Take (15 s) aufnehmen und stoppen, WLAN wieder an. | Das Memo erscheint nach der Verbindung in der History und läuft bis „Done"; nichts doppelt. | |
| M13 | **Beenden mitten im Take.** Take starten, nach 15 s Iris mit Cmd-Q beenden, neu starten. | Beim Start sendet der Outbox, was geschlossen war (Verlust höchstens das offene Segment, siehe I2); die History zeigt ein Memo. | |
| M14 | **Vollbild und Spaces.** Eine App im Vollbild, dann Control-Option-M. Danach auf einen anderen Space wechseln. | Das Panel erscheint über der Vollbild-App und folgt auf den anderen Space. | |
| M15 | **Panel bekommt Tasten, nur auf Klick.** In TextEdit tippen, Control-Option-M, **weitertippen** (die Buchstaben landen weiter in TextEdit). Dann ins Panel klicken (auf eine freie Stelle), Return drücken; danach noch einmal aufnehmen und das Mikrofon-Menü im Panel öffnen. | Solange nicht geklickt wurde, bleibt TextEdit aktiv und bekommt jede Taste. Nach dem Klick löst Return „Stop" aus, das Mikrofon-Menü öffnet sich als normales Menü, das Menü von TextEdit bleibt in der Menüleiste (Iris wird nicht zur aktiven App). Notiere, ob TextEdit nach dem Klick noch Tasten bekommt (erwartet: nein, solange das Panel Key ist) und ob Escape in der Fehlermeldung „Close" auslöst. | |
| M16 | **Eingabe nach Kill.** Zweites Mikrofon anschließen, Take starten, im Panel das zweite Mikrofon wählen, dann Iris hart beenden (`pkill -9 Iris`). Iris neu starten. | Systemeinstellungen › Ton › Eingabe zeigt wieder das Gerät von vor dem Take (nicht das gewählte). Das abgebrochene Memo wird gesendet, was geschlossen war. |  |
| M18 | **Banner nach Verbindungsabbruch.** Wlan/Tailscale aus, vom iPhone ein Memo aufnehmen, das fertig wird, Wlan wieder an. | Der Mac zeigt nach der Wiederverbindung genau einen Banner für das Memo (Route und Überschrift, kein Transkript); ein Memo, das „Failed" oder „Where should this go?" wurde, zeigt den allgemeinen Text. Kein zweiter Banner beim nächsten Wechsel. |  |

## Wave 18 I7: re-test of the three device failures (fixes built, device proof pending)

Fixes (PR `w18-i7-device-failures`), none verified on the phone yet: row 1 the Record control is an `OpenIntent` that asks for the unlock, opens the app and starts the take in the foreground
(`OpenRecorderIntent`, TDD §4 Start paths); rows 15 and 21 a pause keeps the engine running and Resume no longer starts an engine from the background (TDD §4 Capture engine); row 20 a
handed-over activity without a push token is ended for the system to remove when the app goes to the background, and every activity is swept at launch and foreground, 30 minutes at most
(TDD §4 Stale activities). Simulator and unit tests cover the logic; the platform behaviour does not run anywhere but on the phone.

**Before the three takes:** `make device` over the app (same bundle id, outbox untouched), then Settings in Iris › Diagnostics: type a word as the run id (for example `i7`) so one query takes the whole round.
The phone stays unlocked and connected to the tailnet VPN for the install; each step below says when to lock.

**Take A: Lock Screen control (row 1).**
1. Das iPhone sperren (Seitentaste drücken), Display wieder einschalten, aber **nicht** entsperren.
2. Auf dem Sperrbildschirm das Iris-Steuerelement „Aufnehmen“ antippen (zuvor: Sperrbildschirm lange drücken › Anpassen › Steuerelemente › „Record with Iris“ hinzufügen).
3. Erwartet: die Face-ID-Abfrage erscheint (kein stilles Nichts). Mit Face ID entsperren.
4. Erwartet: Iris öffnet sich, die Aufnahme läuft, in der Dynamic Island steht der Timer. Sag „Prüfung eins, Sperrbildschirm“.
5. In Iris auf Stopp tippen.
6. Zweiter Durchlauf aus dem Kontrollzentrum: Von oben rechts nach unten wischen › Iris-Steuerelement antippen › „Prüfung zwei, Kontrollzentrum“ › Stopp in der Dynamic Island.

Headless check (agent): `agw otel "<memo id without dashes>" --env prod`, or a search of `ServiceName:"iris-ios"` with `run.id:i7`, ordered by `seq`. Pass when, for each press: `intent.perform` with
`intent=OpenRecorderIntent`, `process=com.jkrumm.iris` (the app, not `.widgets`), `handler.present=true`; then `intent.result ok`; then `take.phase` `starting` › `recording` with `source=intent`; the memo reaches
`notified` and its transcript holds the spoken sentence. A press with **no** `intent.perform` at all means the app was never reached (the Lock Screen did not run the intent: report the `app.lifecycle` records around
the minute); `intent.result` with `error=StartMemoError.…` means the app was reached and refused, and the same sentence stood in the app's alert.

**Take B: island Pause and Resume, with a lock (rows 15, 21).**
1. Iris öffnen, Aufnahme starten (Aufnahme-Knopf unten), „Prüfung drei“ sagen, die App mit Home-Geste verlassen (Dynamic Island zeigt die Aufnahme).
2. Dynamic Island lange drücken › Pause antippen. Drei Sekunden warten (nichts sagen).
3. Den Bildschirm sperren (Seitentaste), fünf Sekunden warten, wieder entsperren (Face ID), Home-Bildschirm.
4. Dynamic Island lange drücken › Fortsetzen antippen. „Prüfung vier, nach der Pause“ sagen.
5. Dynamic Island › Mikrofon-Wechsel antippen (Mikrofon wechselt zwischen iPhone und AirPods, falls verbunden), „Prüfung fünf, nach dem Wechsel“ sagen.
6. Dynamic Island › Stopp antippen.

Headless check: `take.phase` runs `recording` › `paused` › `recording` › `stopping` with `source=island`, **no** `capture.session.error` and no `failed` phase; no `intent.result` with an `error`; `capture.segment.closed`
has `reason=pause` once; `capture.level` records are absent between the pause and the resume (the engine runs, the samples are dropped) and resume after; the memo's transcript contains „Prüfung drei“, „vier“ and „fünf“
and not the silence in between; `segmentCount >= 3`. If Resume fails again the `capture.session.error` record names the call, the FourCC (`!rec` 561145187, `!int` 560557684, `!pla` 561015905), `app.state` and
`session.category`: send that row instead of the owner's words. The orange microphone dot stays on during the pause and the engine keeps running: a known cost of the fix, not a failure (TDD §4); nothing is written while paused (no `capture.level` records, no audio of the pause in the transcript).

**Take C: no Processing card after Stop (row 20).**
1. Iris öffnen, Aufnahme starten, „Prüfung sechs“ sagen, die App verlassen (Home-Geste).
2. Dynamic Island lange drücken › Stopp antippen. Den Bildschirm sperren und **die App nicht mehr öffnen**.
3. Zwei Minuten warten, dann den Sperrbildschirm ansehen: die Karte „Processing“ ist weg (spätestens eine Minute nachdem die Aufnahme hochgeladen ist).
4. Iris öffnen und wieder verlassen (Home-Geste), Sperrbildschirm ansehen: keine Karte.

Headless check: `liveactivity.end` for the memo with `dismissal=after` and `phase=processing` within a few seconds of the last `outbox.complete.sent` (written by `StaleActivitySweeper.endUnreachable` when the app was
backgrounded, or by the hand-over itself), and a `liveactivity.snapshot` with `reason=background` and `reason=foreground` whose `count` is 0 or whose `age_s` is under 1800. A `count` above 0 with an old
`age_s` after step 4 is the bug; the row's `states` and `memos` fields name the activity and its memo.

Rows to update after the takes: 1 (Lock Screen, Control Center), 15, 20, 21; the `source` of the island buttons is `island`, of the control `intent`.
