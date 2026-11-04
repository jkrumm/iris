# Lead handoff — Wave 21 (lead `iris-w21-lead`, active)

## In flight (2026-11-04 evening)
- **H1** `w21-h1-iris-skill` in hermes-agent (pane t128): skill `iris`, the ```iris block, brain notes via obsidian; the worker fast-forwards
  hermes-agent master itself to validate live, then pushes master. hermes-agent master had 10 unpushed commits (clean, loopback-only); the lead
  pushed them before fanning.
- **S1** `w21-s1-hermes-decides` in iris (pane t129): server + contracts + IrisCore (compat only, `MemoMode` not reduced). Merge only after H1 is
  live (master deploys).
- **A1** after S1 merges.
Briefs (gitignored): `.artifacts/w21-briefs/`. Master `apple.yml` is red since #108 on a flaky `HistorySwipeUITests.testSwipeRightMarksTheRowDone`
(287 s); the PR run was green.
