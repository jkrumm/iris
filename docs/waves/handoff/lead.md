# Lead handoff — Wave 20 (active, lead `iris-w20-lead`, started 2026-11-02 ~19:00)

## State (2026-11-02 21:15)
Briefs in `.artifacts/w20-briefs/` (gitignored; i1, m1, u1 + common rules). Nothing merged yet.
| Item | PR / branch | Review | State |
|-|-|-|-|
| I1 stability | #103 `w20-i1-stability` | round 1 clean; 4 improvements sent (intent logging inside `IntentEvents.run`, player release on failed/cancelled load, `BuiltOnce` keyed + own file + ThreadView composer, `.serialized` handler suites) | worker fixing |
| M1 Mac panel | #102 `w20-m1-panel-bounded` | round 1: 2 blockers (late cancel kills next take; Cancel swallowed) fixed in `bb6251a`; round 2: 1 blocker (`microphones()` after start unbounded) + test-hang hardening sent; no round 3, lead reads the diff | worker fixing |
| U1 floating bars | `w20-u1-floating-bars` (no PR yet) | — | screenshot walks; told to stop hogging the Apple lock and not to commit `W20ShotsUITests.swift` |
U2 is fanned after U1 lands (shared History files). I1 and U1 share `HistoryView.swift` by region (U1: bottom safeAreaInset + scrim; I1: factories + grouping).

## Plan
Batch 1 `w20-batch-1` (I1, M1, U1; one `apple.yml`), merge with `gh pr merge --merge`, close members. Then U2 → own PR or batch 2.
Close-out in PLAN.md (`**Left behind:**`). No server change this wave.

## Lessons
- `factory session wait --on workers` wakes at once while workers idle on their own lock monitors; wait in the foreground on branch pushes instead.
- A worker's screenshot walk under `/tmp/iris-apple.lock` held it ~30 min and starved the others into lockf timeouts.
