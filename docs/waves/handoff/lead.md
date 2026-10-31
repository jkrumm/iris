# Lead handoff — Wave 19 (active, paused for a mini reboot)

State as of 2026-10-31 ~13:30. A fresh lead resumes Wave 19 from here (`docs/waves/PLAN.md` Wave 19; fleet rules in the Fleet section). Nothing is merged
from the wave's Apple tracks yet. Every worker branch is pushed, all worktrees clean (`.claude/worktrees/w19-*`), no worker is running.
`rd agents`: the panes are idle/done; `rd fan --clean iris` only after a PR merges.

## Merged / deployed
- **S1** PR #91 (dependency upgrades) merged as `87c3217`, deployed (`~/.iris/deployed-sha`), `make verify` and `make smoke` green.

## Open PRs (all ready, none merged; the plan is ONE batch train `w19-batch-1`, one `apple.yml` run of ~55 min, then merge and close the members)
| PR | Branch (head) | Item | Review (`agw review --cwd <iris> --pr N`) | CI at head |
|-|-|-|-|-|
| #94 | `w19-i1-data-safety` (`fe9380b`) | I1 outbox bound to its server, delete/hide order, bounded `finishWriting`, cancelled-take cleanup, failed take clears `captureActive` | round 1: 2 blockers, fixed; round 2 **clean** (5 optional improvements, see below) | `check` green; `apple` **red**: `HistorySwipeUITests/testDeleteRemovesTheRowAndUndoBringsItBack` (117 s). Read the log, run that test alone (`make uitest ONLY=HistorySwipeUITests/testDeleteRemovesTheRowAndUndoBringsItBack`, under the lock). It may be the hide/settle change (`HistoryModel.hide/unhide`, `settledBeforeHide`) or a flake; do not bisect the full suite. |
| #95 | `w19-m1-mac-completion` (`4c17963`) | M1 Mac: notification catch-up, stalled-upload panel, key panel, take telemetry, mic recovery after a kill, Mac bound to its server (merged I1's branch in) | round 1: 2 blockers fixed; round 2: 1 blocker (`InputRecovery.setPreferredInput(nil)` cleared the record without a restore) fixed in `4c17963`, **round 3 not run** | `apple` + `check` green |
| #93 | `w19-r1-live-preview` (`cc2c348`) | R1 live on-device preview (`SpeechAnalyzer` behind a port), opaque Stop disc | round 1: 1 blocker (preview wired into no build) + improvements, fixed in `cc2c348`; **round 2 not run** | `apple` + `check` green |
| #92 | `w19-r2-widgets` (`4c7d50c`) | R2 Home/Lock Screen widgets (Record, last memo), snapshot feed wired from History (merged I1's branch in) | round 1 clean; the wiring commit and the fixes after it are not re-reviewed | `apple` + `check` green |
| #96 | `w19-r3-german` (`b0fdb15`) | R3 German strings + `scripts` check against hard-coded strings. Opened by the worker before the stop order; **based on master before the batch, rebase late** | not reviewed | `check` green, `apple` not run |

Parked branches without a PR (pushed as `wip:` commits at the stop order, untested): `w19-i3-telemetry-ui-debt` (`8dd2283`, I3: only TrendRow/VolumeChart fidelity and stable
message-block ids so far; telemetry concurrency items NOT done) and `w19-i2-late-tail` (`79e8632`, I2, branched from `w19-i1-data-safety`, "untested"; design brief in
`/tmp/iris-w19-briefs/i2.md` is lost on reboot: it is the Wave 19 I2 line in PLAN.md plus "smallest design, new outbox item kind, deterministic UUIDv5-style memo id, audio never
deleted before delivery, under 400 lines, not converged after round 2 -> Left behind"). Briefs for I1/M1/R1/R2/R3/I3 were in `/tmp/iris-w19-briefs/` (lost); the PR bodies carry the scope.

## Next steps (in order)
1. Fix #94's red UI test. Round-3 `agw review` #95, round-2 #93, re-check #92's wiring (`agw review` converges poorly on big capture/notification code: after round 2 fix only data-loss, privacy, security, crash blockers).
2. Build `w19-batch-1` from `origin/master`: merge #94, #95, #93, #92 (each with its own merge commit; #95 and #92 already contain #94's commits, expect trivial conflicts in `CompositionRoot.swift`, where #93 and #92 both add a line), open it as one PR, `apple.yml` once. Green -> merge, close the member PRs as merged by it. Red -> the failing test names the PR; fix on the batch branch.
3. Then #96: `git rebase origin/master`, resolve (new strings from the batch need `de` entries; its check script will list them), `agw review`, merge it alone (or in batch 2 with I3).
4. I3: finish the telemetry items (flush/recovery concurrency, no background assertion on a hung send, quarantine off the main actor, uid-free audio port names) and the rest of PLAN.md Wave 19 I3, PR, review, batch 2. I2: rebase on master after the batch, test, review; if it does not converge after round 2 write the design into TDD §4 and Left behind.
5. Open improvements from reviews, not blockers: #94: unbound legacy/no-connection items are sent to any server (stamp them on load or hold them), `CreatedMemoLog` has two parallel handlers, `discardFiles` swallows removal errors, `TakeController.sessionUpdated` releases `captureClaim` without checking it still belongs to the failed take, a wedged-server bound item waits forever (show a reason). #95: notifier size/structure, test scaffolding compiled into production files. #93: analyzer port for `LivePreviewSpeechEngine` (untested device-only code).
6. S1 server side is done; if a batch changes the server (none so far) deploy + `make verify` + `make smoke`.
7. D1 (owner's hardware batch) only when he says so; new device rows were added to `docs/spikes/device-checklist.md` by M1 (Mac), R1 (preview P-rows) and R2 (widgets W-1..W-8). New surfaces for his async review are in `docs/design/README.md` (R1 preview, R2 widgets).
8. Close-out: tick Wave 19 in PLAN.md, write `**Left behind:**` exactly, deploy/verify, stop (the mother spawns the next lead).

## Lessons from this session
- A `rd fan` flood while the Xcode lock is held starves the workers that matter: fan at most three Apple workers at once; the lock is `lockf -t 1800 /tmp/iris-apple.lock`.
- `agw review` on four PRs at once took ~35 min; `agw run wait` returns after 110 s with exit 10 (loop it). Worker panes listed as `done` can still hold uncommitted fixes: check `git status` in the worktree before reading a diff.
- `rd say` needs the exact agent name from `rd agents` (the M1 name is `iris-w19-m1-mac-completio`, truncated); a pane id (`w4V:p3G`) always works.
- Quota at 13:00: `iu` 4/61, `me` 9/67, `me2` walled until 11-01 18:00.
