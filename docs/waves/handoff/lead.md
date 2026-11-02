# Lead handoff — Wave 20 (active, lead `iris-w20-lead`, started 2026-11-02 ~19:00)

## State (2026-11-02 22:15)
Briefs in `.artifacts/w20-briefs/` (gitignored; i1, m1, u1, u2 + common rules).
| Item | PR / branch | Review | State |
|-|-|-|-|
| I1 stability | #103 `w20-i1-stability` | round 1 clean, 4 improvements taken (`7e9af7a`) | in batch 1 |
| M1 Mac panel | #102 `w20-m1-panel-bounded` | 2 rounds + lead read of round 3 (`91f5cad`); all blockers fixed. `RecordingPanelKeyTests` "making the panel key" fails on the mini every run (pre-existing, Wave 19; CI is the gate) | in batch 1 |
| U1 floating bars | #104 `w20-u1-floating-bars` | round 1 clean (optional: scrubber RTL/cancel, a11y step value, `statusBarScrim` home) | in batch 1 |
| Batch 1 | #105 `w20-batch-1` (worktree `.claude/worktrees/w20-batch-1`) | lint + strings green locally | `apple.yml` running |
| U2 rows/sheets | `w20-u2-rows-sheets` (pane t9h), branched from master + `origin/w20-batch-1` merged in | — | working |

## Next
Batch 1 green → `gh pr merge 105 --merge`, close #102/#103/#104 as merged by it. Red → the failing test names the PR; fix on `w20-batch-1`.
U2 → review → its own PR (apple.yml once). Close-out in PLAN.md (`**Left behind:**`). No server change this wave.

## Lessons
- `factory session wait --on workers` wakes at once while workers idle on their own lock monitors; wait in the foreground on branch pushes instead.
- A worker's screenshot walk under `/tmp/iris-apple.lock` held it ~30 min and starved the others into lockf timeouts; a hung IrisMac test held it 18 min at 0% CPU (killed; per-test time limits now in the briefs).
