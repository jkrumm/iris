# Mother handoff — Iris fleet (R1–R5)

Rewritten 2026-10-28 at the owner's pause; status updated at the resume the same day. This file is the next mother's whole memory: read it, then `docs/waves/PLAN.md`
(the Fleet section, Waves 10–15, the Fleet backlog), `docs/PRD.md`, `docs/design/feedback-round-{1,2}.md` (binding, round 2 wins)
and skim `docs/TDD.md`. Role contract: `~/.claude/skills/wave/roles/mother.md` (lead: `roles/lead.md`, workers: `roles/worker.md`).

## Status: PAUSED after Wave 20 (2026-11-03 ~00:40 CET)

Wave 20 (pre-hardware hardening from the 2026-11-02 audits) done, master `7d3d0cc`, Apple-only, production unchanged. Lead `iris-w20-lead` stopped.
Resume on: the owner's hardware batch D1 (device build of master once the phone tunnel is up; it was `disconnected` all of 2026-11-02), his look at
`docs/design/fidelity/w20.md`, or the enrolment email. Wave 21 candidates: Wave 20 Left behind (contract-side row cost / candidates / filter counts, audit polish).
**Pause (owner decision 2026-11-01 19:30, via the software-factory program lead: finish Wave 19, then pause; start no new wave):** resume only on the owner's feedback (hardware batch D1 on a fresh device build of master,
UI review of R1/R2 surfaces in `docs/design/README.md`) or the Apple enrolment email (then D2/S3/APNs/TestFlight). **On resume:** write Wave 20 from the
Fleet backlog + Wave 19 Left behind, spawn a lead under a FRESH factory key (`iris-w20-lead`, see Lessons; never `rd wave`), start
`docs/waves/handoff/mother-watch.sh 20 <lead>` in the background, `factory session wait --on workers`. Worker briefs of Wave 19: `~/.iris-fleet/iris-w19-briefs/`.
Quota 2026-11-01 17:40: iu 69% (11-04 16:00), me 91% (11-05 06:00), me2 reset 11-01 18:00. All walled -> wait, never IU API tokens.
**Spawn (lead):** `cd ~/SourceRoot/software-factory && secrets-run run --env-file=.env.tpl -- factory spawn create <key> --repo ~/SourceRoot/iris --role lead
--parent iris-mother --prompt 'Read docs/waves/PLAN.md and ~/.claude/skills/wave/roles/lead.md. You are the fleet lead for the active wave (Wave <n>). Brief
workers with rd fan, review, merge, close out the wave in PLAN.md (the label must be exactly **Left behind:**), and stop; the mother spawns the next lead.'`;
check `factory spawn get <key>` shows a `t…` pane. Watcher: reasons in `/tmp/iris-mother/watch.out`. The factory re-wakes the mother on every idle turn of the
lead ("workers done: … idle"): check master + CI, re-declare the wait, end the turn; block on `gh run watch` (≤ 580 s) when a CI run is the only thing pending.
Timestamps from `gh` are UTC (CET = UTC+1): a 2026-11-01 false "stuck CI" alarm came from mixing them.
Mini rules: every Apple build under `lockf -t 1800 /tmp/iris-apple.lock`.

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

## Cross-fleet

- **Gateway sunset (agent-workflows, 2026-10-29):** both contracts arrived. Audio door → Wave 16 S3; decide + triage (ported as-is,
  host 7791, `x-agw-purpose: iris`, synchronous, abort = cancel) → Wave 16 S4. Wave 17 is free for backlog again. Questions to their
  side: `rd say agent-workflows-w1`. **Done 2026-10-29:** S3 `4ca67dc` + S4 `1b36891` deployed, smoke green with a real summary, review on `agw review --pr`;
  agent-workflows-mother told. agent-gateway's review tool now refuses.

## Open owner items (none block the code, all wait for the owner)

- **Spoken reply vs. playing reply / recording** (asked 2026-10-30 in chat): as built it interrupts the player and pauses a recording;
  queue or defer? Wave 17 I3 waits for the answer; record it in PLAN.md.

- **Requesty / triage routing** (above): production summaries are failing. Asked again 2026-10-28 16:49 (move triage off
  Requesty?): **denied**. Leave it; do not re-ask, `make smoke` red at `summarize` is accepted. Owner then decided (same day): **summarize becomes optional
  in Wave 16** (memo ends `done` without a summary); that item is fixed in PLAN.md's Wave 16 sketch.
- **Apple Developer Program enrollment:** owner bought it 2026-10-29 evening, **enrollment pending** (Apple email next) (free-team route and ntfy/Pushover dropped;
  research run `01a1888f-…`). Owner is home, iPhone can be paired. Next: device wave after Wave 16 (S1–S3, device exit checks, TestFlight).
  Previously expected ~2026-10-28: then the APNs `.p8` and App Store Connect key go into 1Password
  via `ask-human.sh`, and TestFlight (backlog 3) opens.
- **iPhone paired 2026-10-29 19:51** (wired): iPhone 15 (`iPhone15,4`, Dynamic Island), **iOS 26.6.1** (the simulator runs 27: device
  checks cover the iOS 26 code paths; app target is 26.0). UDID in `xcrun devicectl list devices` (name JoPhone). Since 2026-10-29 ~20:00: Developer
  Mode on, owner's Apple ID in Xcode (Personal Team until enrollment clears), one valid Apple Development identity (the WWDR G3
  intermediate had to be added to the login keychain: identity showed but `-v` said 0 valid). Device not yet registered (first
  `-allowProvisioningUpdates` build does it). A codesign key-access dialog on the mini's screen needs the owner's "Always Allow". Then spikes S1–S3, every device exit check.
- **Outbox reset (asked 2026-10-28 in chat):** A quarantine vs B delete. No answer by Wave 16's writing: A ships in Wave 16 I1;
  a delete variant only on the owner's word.
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

- **Respawning a lead for the same wave:** `rd wave` goes through the factory, whose spawn key is `<repo>-w<n>` and idempotent: a second `rd wave` for Wave 19 returned the dead `iris-w19` and started nothing, and it ignores `RD_WAVE_MODEL` (role `wave`, sonnet). Spawn a lead with `cd ~/SourceRoot/software-factory && secrets-run run --env-file=.env.tpl -- factory spawn create <new key> --repo ~/SourceRoot/iris --role lead --parent iris-mother --prompt '...'` (2026-11-01: `iris-w19b`, opus, account me, pane t37).

- **Quota is the fleet's real constraint.** A refused spawn ("no Claude account has room") is retried every 10 min in a background
  loop; never spill to IU API tokens. A lead or worker hitting the 5-hour limit resumes on its own at the reset; wait, don't respawn.
- **Watching a lead:** `wave-watch.sh` fires when the lead goes idle, and an Opus lead idles while its own watcher waits on
  workers. Poll `origin/master`'s PLAN.md for `Wave <n> .*status: done` plus `rd agents` for `blocked` (a 2-min loop, 60–90 min
  heartbeat, output to a file). Read the lead's pane (`rd read`) only when master has not moved for an hour.
- **The lead's Claude prompt-suggestion line** (ghost text under the pane) can reveal a real blocker (it surfaced the Requesty 402).
- **`rd wave` blocked at startup** = folder-trust prompt for an account or worktree path: read the pane and accept it.
- **"Dangerous rm" prompts** block agents even under skip-permissions: `herdr agent read <name> --source visible`, answer if safe.
- **Review = `agw review --cwd <iris> --pr <N>`** (agent-workflows CLI, cheap models) since 2026-10-29, owner direction. Never
  `agw-legacy` or agent-gateway's `/api/jobs` for review (its review tool refuses). Exit 10 → `agw run wait <runId>`. `/research` is
  `agw research`.
- **`rd wave`'s green gate** needs the previous wave's label exactly `**Left behind:**` (a suffix inside the bold fails it); the lead
  prompt now says so.
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
