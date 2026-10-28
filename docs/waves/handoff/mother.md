# Mother handoff — Iris fleet (R1–R5)

Rewritten 2026-10-28 at the owner's pause; status updated at the resume the same day. This file is the next mother's whole memory: read it, then `docs/waves/PLAN.md`
(the Fleet section, Waves 10–15, the Fleet backlog), `docs/PRD.md`, `docs/design/feedback-round-{1,2}.md` (binding, round 2 wins)
and skim `docs/TDD.md`. Role contract: `~/.claude/skills/wave/roles/mother.md` (lead: `roles/lead.md`, workers: `roles/worker.md`).

## Status: RESUMED by the owner (2026-10-28), run through the night

Wave 15 written in full and active; a lead runs it. Quota: iu and me at 100% weekly (iu resets 10-28 16:00, me 10-29 06:00),
me2 has room. All walled → wait for the next reset (`claude-account usage`), never IU API tokens. Stop only for the four reasons.

## Mission

Build Iris R1–R5 (PRD §Release plan) as a self-driving loop: backlog item → wave → lead (Opus) → workers (default model, `rd fan`)
→ merged, green, deployed → next. Iris is the owner's voice channel into his agent estate; there is one user, the owner.

## State at the pause

- **Waves 10–14 done** (PLAN.md has each Left behind). Shipped: design round 2; R2 routing on the server (mode, spoken prefix,
  agw `decide`, `needs_route` + answers/corrections, journal, herdr, Chat, typed memos, agw `caller`); R3 server (threads from
  Iris's own memos, FTS5 search + filters + `pinned`, stats with per-step-and-route medians, telemetry relay, memo flags + soft
  delete/undo/purge, automatic retries, Mermaid via Pele → SVG/PNG assets, speech-ready answers); iOS on the simulator (History
  shell with tabs, chips, filter sheet, swipe + undo; memo detail with player, waterfall, attempts; Stats; Settings with
  Diagnostics and an outbox port; typed composer).
- **Production:** server `d3d8211` deployed, `make verify` healthy, DB `user_version` 11, no `.bak` left in `~/.iris/data`.
- **`make smoke` fails at `summarize`** and will keep failing: agw `triage` runs on an IU model through Requesty, which answers
  402 Insufficient Balance. **Owner decision 2026-10-28: Requesty is not topped up.** Every Hermes memo ends `failed(summarize)`
  after a successful `act` (the reply exists; journal and herdr use templates and are fine). The adversary angle of `agw review`
  fails on the same 402.
- **CI:** `check` green; `apple.yml` was still running on `e9f7258` (I3) at the pause — check it first on resume.
- **Wave 15 is a sketch, `pending`** in PLAN.md (R3 conversations + simulator parts of R1 capture). No tabs or worktrees are open.

## Resume point

1. Check `gh run list` (`apple.yml` on `e9f7258` and later green) and `make verify`.
2. **Unblock `summarize`:** ask the owner (stop reason 2, spend, or an agent-gateway routing change he owns) to move agw `triage`
   off Requesty or fund it. Then `POST /v1/memos/:id/retry {from: "summarize"}` on the memos that failed meanwhile, and `make smoke`.
3. Write **Wave 15** in full (backlog 7 conversations: thread view from a History row, Hermes-scope markdown, highlighted code,
   tables → cards, Pele images with zoom, reply by voice/text, the iPhone reply flow as a new surface rendered for async owner
   review; plus backlog 2's simulator parts: start recording from any screen with a top banner, the whole-memo/chat outbox).
   Fold in Wave 14's "for the next wave": a **production composition** on iOS (real `URLSessionAPIClient` +
   `AuthenticatedMediaSource`; today `CompositionRoot` is fake-only).
4. Then backlog 5 and 8's simulator parts; device items (1, 3, the exit checks of 2 and 5) when the owner has the iPhone paired.

## Open owner items (none block the code, all wait for the owner)

- **Requesty / triage routing** (above): production summaries are failing. Asked again 2026-10-28 16:49 (move triage off
  Requesty?): **denied**. Leave it; do not re-ask, `make smoke` red at `summarize` is accepted.
- **Apple Developer Program enrollment** (expected ~2026-10-28): then the APNs `.p8` and App Store Connect key go into 1Password
  via `ask-human.sh`, and TestFlight (backlog 3) opens.
- **iPhone pairing** when the owner is home: spikes S1–S3, every device exit check.
- **Swipe detail:** "further right/left" is a second swipe button, not a second full-swipe threshold (native `.swipeActions`).
  A custom gesture only if the owner asks.
- **Account `me`** showed `auth FAILED` intermittently on the mini (`claude-account usage`); a re-login is the owner's.

## Fleet shape and models

- **Mother:** Opus. Never reads source, never merges. Owns PLAN.md, this file, spawning and closing leads.
- **Lead:** `RD_WAVE_MODEL=opus RD_ORCHESTRATED=1 rd wave iris 'Read docs/waves/PLAN.md and ~/.claude/skills/wave/roles/lead.md.
  You are the fleet lead for the active wave (Wave <n>). Brief workers with rd fan, review, merge with rd merge, close out the wave
  in PLAN.md, and stop; the mother spawns the next lead.'` Workers on the default model via `rd fan`.
- **One active wave at a time.** The lead never flips the next wave active unless the mother has written it.

## Lessons (do not relearn)

- **Quota is the fleet's real constraint.** A refused spawn ("no Claude account has room") is retried every 10 min in a background
  loop; never spill to IU API tokens. A lead or worker hitting the 5-hour limit resumes on its own at the reset; wait, don't respawn.
- **Watching a lead:** `wave-watch.sh` fires when the lead goes idle, and an Opus lead idles while its own watcher waits on
  workers. Poll `origin/master`'s PLAN.md for `Wave <n> .*status: done` plus `rd agents` for `blocked` (a 2-min loop, 60–90 min
  heartbeat, output to a file). Read the lead's pane (`rd read`) only when master has not moved for an hour.
- **The lead's Claude prompt-suggestion line** (ghost text under the pane) can reveal a real blocker (it surfaced the Requesty 402).
- **`rd wave` blocked at startup** = folder-trust prompt for an account or worktree path: read the pane and accept it.
- **"Dangerous rm" prompts** block agents even under skip-permissions: `herdr agent read <name> --source visible`, answer if safe.
- **`agw` CLI is `agw-legacy`** since 2026-10-28. Its review CLI prints only the summary; findings are in `GET /api/jobs/<id>`
  `.job.result`. `/research` was down (503) during Wave 14.
- **Merge train:** `rd merge` fails on a draft PR (`gh pr ready`), needs a worktree holding the branch, runs `make check` but not
  `make e2e` (run it before the train for server-behaviour PRs). Parallel workers on shared additive files (AGENTS.md, TDD,
  registry, conformance, FakeAPIClient) conflict on every rebase: land one at a time, resolve in the lead. One `xcodebuild` worker
  at a time (parallel builds get SIGTERMed). A contract change carries its Swift `IrisCore` follow-up in the same brief.
- `make run-sim` / `screenshot` leave the simulator booted: `xcrun simctl shutdown all`. `scripts/mbm tap` needs `--post-delay 2`.
- `ask-human.sh ask '<question>' --cmd true` is a yes/no channel to the owner's MacBook (Run = yes, `done` exit 0).

## Carry-forward debt (assign inside backlog items)

- Server: audio-gateway STT/speech timeouts still count as transient; a waiter on a thread queue holds a `driveAll` slot; herdr's
  per-pane queue is unbounded; Pele assets are written outside the `completeStep` transaction; no asset backfill for older replies;
  multi-word spoken tab names (needs the matched word count on the decision row).
- iOS: no production composition; the player polls every 250 ms (no time observer, no waveform); `StatsModel`/`SettingsModel.load()`
  lack History's generation guard; composer Cancel stays enabled during a send; the cost tile prints `$1,6200`; Live Activity client
  phases recording/paused/uploading; package wiring onto `IrisCore`; crash-file protection class; `.xcstrings`.
- TDD stays true: amend it whenever a wave changes a design decision.
- Housekeeping (backlog 10, after R3's screens ship): delete the round-1/2 mockup image objects via `/img` (incl. the stray
  `r2-detail-light`), `iumac:/tmp/iris-mockups.html` + `/tmp/iris-mockups/`, `docs/design/renders/`.
