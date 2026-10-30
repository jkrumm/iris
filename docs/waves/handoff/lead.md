# Lead handoff — Wave 17

State as of 2026-10-30. PLAN.md is the plan; this file is the lead's working memory.

## State (2026-10-30 ~11:05, lead stopped at a usage limit)

| Item | PR | State |
|-|-|-|
| H1 | #46 | merged; bucket objects under `private/` not deletable from the mini (Left behind) |
| D1 | #48 | merged `d24476b`; typed memo `3418749a…` from the phone done |
| S1 server follow-ups | #47 | agw clean; e2e green; apple CI failed 3x on the UI-query flake (unrelated); held for #51, then re-run, merge, deploy + verify + smoke |
| I1 capture/outbox | #49 | agw round 2 clean + reset-race fix 98af773 (lead read it); train `rd merge` running (`/tmp/iris-w17/merge-49.txt`); asked I1 to stress `CaptureSessionTests.aFailedTakeCanBeCancelled` (flaked on #50 CI) |
| S2+I4 transcribe mode | #50 | agw blocking fixed fe240bc (lead read it); local server checks + e2e green; apple CI re-run after the IrisCapture flake; merge with `--check 'true' --no-ci` once green, then deploy + smoke |
| I2a UI-query flake | #51 | agw clean; waiting for apple CI; merge FIRST when green, then re-run #47/#49/#50 CI |
| I2 UI follow-ups | #52 | just opened, not reviewed; carries 3 #51 review improvements + the "Connected" label (owner) |
| D1b lost take | branch only | audio delivered (memo 82c8d008 needs_route, owner's route choice); fix dae7059 (segments by file name); lead asked: 409 must set aside, not delete, unless server segmentCount covers it; rebase on master; device proof; PR after #49 lands |
| D2 spikes | branch | phase 1 plan pushed f8aa3069; phase 2 waits for D1b's device proof, builds from D1b's branch |
| I6 route config render | — | working (placement approved: Settings "Routes" row behind the review flag) |
| C1 CI diet | — | working; scope add: rename derived data to `apple/.dd.noindex` (Spotlight mds_stores at 91% CPU) |
| I5 | — | not started; waits for I2; include feedback-device-1 §6 (level meter) |
| D3 | — | one ask-human question after D2 lands |
| I3 | — | no owner answer → Left behind |

Review follow-ups for Left behind: #47 sweep limit/ENOENT/stat concurrency/fake order/hold simplification; #49 unmovable stray files invisible,
hung stop deactivates the session, zero-segment grace, duplicated set-aside read, take-state consolidation; #50 RoutableMode type, Swift
capability facts; #51 two readability items. Owner notes: three device tokens printed in D1's session (may rotate); token entry UX; ask-human
reported done within a second; mini load (Spotlight). Train lesson: the local `lockf … make check` in `rd merge` times out under load, use
server checks + CI for Apple; `rd merge` with `--check 'true' --no-ci` for a checked, CI-green head behind docs-only master commits.

## Apple build slot

Every xcodebuild/simctl/devicectl command runs under `lockf -t 900 /tmp/iris-apple.lock …` (exit 75 = busy, retry). This lets D and I
workers run in parallel while builds serialize.
