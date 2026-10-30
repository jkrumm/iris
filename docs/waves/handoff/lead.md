# Lead handoff — Wave 17

State as of 2026-10-30. PLAN.md is the plan; this file is the lead's working memory.

## In flight (rd fan, briefs in /tmp/iris-w17/)

| Item | Branch | Agent |
|-|-|-|
| D1 device bring-up | w17-d1-device-bringup | iris-w17-d1-device-bringu |
| S1 server follow-ups | w17-s1-server-followups | iris-w17-s1-server-follow |
| I1 capture/outbox follow-ups | w17-i1-capture-outbox | iris-w17-i1-capture-outbo |
| H1 housekeeping | w17-h1-housekeeping | iris-w17-h1-housekeeping |

Queued: D2 after D1 lands; I2 after I1 lands (shared app files); D3 only if the enrolment cleared (one ask-human question after D2);
I3 waits for the owner's answer in PLAN.md (none yet → Left behind).

## Apple build slot

Every xcodebuild/simctl/devicectl command runs under `lockf -t 900 /tmp/iris-apple.lock …` (exit 75 = busy, retry). This lets D and I
workers run in parallel while builds serialize.
