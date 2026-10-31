# Lead handoff — Wave 18

State as of 2026-10-31 05:25. PLAN.md is the plan; this file is the lead's working memory.

**Merged to master:** S1 #68 (deployed `e16fbd4`, verify + smoke green); #72 D1 docs; batch 1 #74 (C1, I5a scale); batch 2 #80 (I1 pause on take start,
M1 Mac menu-bar, I4 UI debt, I5b detail + route sheet); batch 3 #85 (I5a History, I5c thread + composer, I5d take/Live Activity, I5e Stats +
Settings); batch 4 #86 (I3 capture data-safety, I6 device observability). Every batch: one `apple.yml` run, green.

**Open:** #87 I7 (three device failures: Lock Screen `OpenIntent`, island Resume keeps the engine running, stale Processing activity) — worker
`w18-i7-device-failures` (pane w4V:p36) is fixing agw round 1 (5 items; the other 4 are Left behind); then I read the diff, batch 5 = #87 (+ anything
else), merge, then a fresh device build for the owner (`make device`, D worker pane w4V:p2N is kept open) before ~08:00.

**Parked branches (Left behind):** `w18-i23-capture-recovery-debt` (I2 PCM shadow recovery, PR #71 closed), `w18-i1b-late-tail` (late tail as its
own transcribe memo, owner default 2). **Not started:** M2 (Mac capture), D1 hardware batch (owner), D2/D3 (enrolment question pending in the
human queue: `20261030T203639-25481`, D1 ready `20261030T204053-5700`).

**Review convergence:** agw does not converge on large capture/notification code; rule used: fix data-loss/privacy/security blockers, rest to Left behind.
**Apple build slot:** every xcodebuild under `lockf -t 1800 /tmp/iris-apple.lock`.
