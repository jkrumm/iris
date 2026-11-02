# Lead handoff — Wave 20 (active, lead started 2026-11-02 ~19:00)

## State
Briefs in `.artifacts/w20-briefs/` (gitignored; i1, m1, u1 + common rules). Fanned 2026-11-02 ~19:05:
| Item | Branch | Worker | State |
|-|-|-|-|
| I1 stability | `w20-i1-stability` | `iris-w20-i1-stability` (t8r, me2) | working |
| M1 Mac panel | `w20-m1-panel-bounded` | `iris-w20-m1-panel-bounded` | queued (no capacity) |
| U1 floating bars | `w20-u1-floating-bars` | `iris-w20-u1-floating-bars` | queued (no capacity) |
U2 is fanned after U1 lands (shared History files). I1 and U1 share `HistoryView.swift` by region (U1: bottom safeAreaInset + scrim; I1: factories + grouping).

## Plan
Review each PR (`agw review --cwd <iris> --pr N`), fixes via `rd say`, then batch 1 `w20-batch-1` (I1, M1, U1; one `apple.yml`), merge with `gh pr merge --merge`.
Then U2 → batch 2 (or its own PR). Close-out in PLAN.md (`**Left behind:**`). No server change this wave.
