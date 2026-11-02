# Lead handoff — Wave 20 (closed, lead `iris-w20-lead`)

## Closed (2026-11-03 ~00:40)
Wave 20 is done in PLAN.md (status marker `done`, `**Left behind:**` written). Master `7d3d0cc`: batch 1 #105 (#103 I1, #102 M1, #104 U1) and U2 #106,
each one green `apple.yml` run. No server change; `make verify` healthy. Carried: D1 (owner hardware batch, now on a device build of `7d3d0cc`), D2 (enrolment).
No worker running; all Wave 20 worktrees and panes reclaimed. Kept: the parked I2 branches `w19-i2-late-tail`, `w19-i2b-late-tail`, `w18-i23-capture-recovery-debt`.
Briefs (gitignored) in `.artifacts/w20-briefs/`. The next lead is the mother's call.

## Lessons
- `factory session wait --on workers` wakes at once while a worker idles on its own lock monitor; wait in the foreground on branch pushes / `gh run view` instead.
- Screenshot walks and hung tests can hold `/tmp/iris-apple.lock` for 20-30 min: one walk per acquisition, per-test time limits, `timeout 1500` around test runs.
- Fanning the next U item on master + the open batch branch saves the batch's CI hour; GitHub then marks members merged by the batch on its own.
