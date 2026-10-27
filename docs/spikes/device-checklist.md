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

Findings that change the design go to the matching spike file and into `docs/TDD.md` §4 / §13.
