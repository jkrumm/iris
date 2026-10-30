# Lead handoff — Wave 17

State as of 2026-10-30. PLAN.md is the plan; this file is the lead's working memory.

## State (2026-10-30 ~08:50)

| Item | PR | State |
|-|-|-|
| H1 housekeeping | #46 | merged `200194f`; bucket objects under `private/` not deletable from the mini (Left behind) |
| S1 server follow-ups | #47 | agw clean (5 improvements → follow-ups); e2e green; apple CI flaked (CaptureUITests UI-query timeout), re-run attempt 2; then deploy + verify + smoke |
| D1 device bring-up | #48 | agw: 2 blocking fixed (d854f81), lead read the fix; typed memo `3418749a…` from the phone done; train running |
| I1 capture/outbox | #49 | agw: 2 blocking (token PUT per-memo gate, double finish on hung stop) sent back |
| I2 UI follow-ups | — | working; also owns the "Connected" label (owner) and the UI-query flake incl. CaptureUITests |

Queued: D2 after #48 lands; D3 one ask-human question after D2; I3 has no owner answer → Left behind.
Owner notes: three device tokens printed in D1's session (owner may rotate); token entry UX (token=device pairs) was painful;
`ask-human.sh ask` reported `done` within a second three times (dotfiles, not iris).

## Apple build slot

Every xcodebuild/simctl/devicectl command runs under `lockf -t 900 /tmp/iris-apple.lock …` (exit 75 = busy, retry). This lets D and I
workers run in parallel while builds serialize.
