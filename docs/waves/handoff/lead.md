# Lead handoff — Wave 21 (lead `iris-w21-lead`, active)

## State (2026-11-04 ~22:00)
- **H1 done:** hermes-agent `4a95400..e044b5b` (skill `iris`, `iris-note.py`, SOUL row), live, `agw review` clean. The lead pushed 10 earlier
  unpushed hermes-agent commits first (clean, loopback-only).
- **Owner feedback (`79be81d`) arrived while S1/A1 ran:** summarize stays (agw `triage`), block = `{kind, headline}`, three visible buttons,
  software factory path, P1 pulled in. Response:
  - **S1** PR #119 (reviewed clean, green) is **not merged**; superseded by **S1b** `w21-s1b-summarize-stays` (pane t12j): #119 rebased on
    master + summarize restored + `hermes_headline`. #119 gets closed by S1b.
  - **H1b** `w21-h1b-factory-headline` (hermes-agent, queued for capacity): block without `spoken`, factory path.
  - **A1** `w21-a1-apple-follows` (pane t12g) amended by `rd say` (three buttons, Transcribe control, Mac pair); based on S1's branch, switches
    to S1b's once it exists, rebases on master after S1b lands.
  - **P1** `w21-p1-paid-signing-apns` (pane t12k): headless paid signing + APNs registration + phone proof. Owns `IrisApp.swift`,
    `Push*.swift`, `project.yml`, entitlements; A1 owns the rest of `apple/**`.
- Merge order: H1b live → S1b (deploys; `make verify`, `make smoke` with `kind`) → A1 + P1 (batch, one `apple.yml`).
- Left behind so far: `op://mini/agent-workflows/API_SECRET` stays used (summarize stays). Master `apple.yml` red since #108 on a flaky
  `HistorySwipeUITests` (A1 looks at it). `cron/dispatch_held.json` untracked in hermes-agent (not ours).
Briefs (gitignored): `.artifacts/w21-briefs/`.
