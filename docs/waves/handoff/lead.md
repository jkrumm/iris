# Lead handoff — Wave 16

State as of 2026-10-29 evening. PLAN.md is the plan; this file is the lead's working memory.

## Landed (merged, reviewed with `agw review --pr`)

| Item | PR | Notes |
|-|-|-|
| S2 server follow-ups | #36 | review clean + 2 improvements taken |
| S1 summarize optional | #37 | 1 blocking (boot repair crash-loop) fixed; deployed, repair moved 1 memo with a backup |
| I1 outbox reset + capture | #38 | 2 review rounds, 5 blocking fixed |
| S3 audio door | #39 | 1 blocking fixed; deployed, smoke + `/speech` proven with `agw-run-id`s |
| S4 decide + triage on the host | #40 | 1 blocking fixed; deployed, smoke green with a real summary, decide 0.999 hermes, the one summary-less memo retried |
| I2 iOS follow-ups | #41 | 1 blocking fixed; CI snapshot failure was a host line-wrap difference, fixture made one-line |
| S5 host caller attribution | #42 | clean; deployed; `agw.runs` shows purpose/caller/project `iris` for decide + triage |
| I4 reply flow | #45 | review clean; CI fix (UI-test race, job timeout 75 min) read by the lead |
| I3 R2 routing on iOS | #44 (supersedes #43) | regression: History's route sheet moved to `RootView` (bisection in the PR); 3 review rounds, round 3 under the convergence rule |

## Status

Wave 16 closed 2026-10-30: I4 merged as #45 (`cdb1e5f`), PLAN.md ticked, **Left behind:** written there. Nothing in flight.

## Train notes

- `rd merge` waits 1200 s for CI; the Apple job often takes longer, and docs commits on master restart it. Pattern that works: watch the
  PR head's `apple` run (`gh run watch <id>`), then `rd merge iris --check 'true' <branch>` when the head is unchanged and already checked.
- Server PRs: `--check 'make check-server check-contracts guard && make e2e'`; the Pele render test times out under xcodebuild load (retry).
- Hosted runner flake: `ReplyFlowReviewUITests` "Timed out while evaluating UI query" (once on #40).

## Follow-ups collected (for Left behind)

See the Left behind paragraph once written; raw list kept in the lead's session: I1 round-2 leftovers (discard hides before the outbox
opens, token registrar re-register race, double Reset tap, stop-timeout tail segment quarantined not uploaded, sweep behind a store port);
S2 (no boot sweep of crash-orphaned asset files, staging in the sqlite adapter); S1 (summary-less alerts use a transcript headline; rollback
is one-way); S4 (5xx retries can bill a second run, no Idempotency-Key per contract); I2 (unordered History insert channel, eviction on the
main actor, Undo re-downloads, in-flight download lands after eviction, runner stall sampling needs a workflow step); I3 (second
`memo.done` while downloading is not auto-spoken; a `load()` overlapping a mic-rule pick leaves Settings showing the old choice;
`playReply` duplicates the speakable rule; route sheet wiring duplicated; owner decision: a finished memo's spoken reply interrupts a
playing reply and pauses the detail's recording: keep, queue or defer).
