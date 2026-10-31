# Lead handoff — Wave 18 (closed)

State as of 2026-10-31 08:50. PLAN.md Wave 18 has the close-out and the Left behind block; this file is only what the next lead needs first.

**Master `b853215`:** everything of Wave 18 except D1 / D2 / D3 and the parked late tail (see PLAN.md). `apple.yml` on master was running at close (51 min per run);
`check` green. The server did not change after S1 (`e16fbd4`, `make verify` + `make smoke` green then).
**Phone:** `b853215` is installed over the old build (launch failed: phone locked). The owner's hardware batch is next, steps in `docs/spikes/device-checklist.md`
(Wave 18 I7, row 8a, Mac rows M1-M14).
**Parked branches:** `w18-i23-capture-recovery-debt`, `w18-i1b-late-tail`. All other worker branches and worktrees are removed.
**Rules that held:** one `xcodebuild` fleet-wide under `lockf -t 1800 /tmp/iris-apple.lock`; Apple PRs in batch trains; after review round 2 only data-loss / privacy /
security / crash blockers; close a worker pane when its PR is merged; build the phone from a detached worktree of `origin/master`, never from the shared checkout.
