# Mother handoff — Iris fleet (R1–R5)

Written 2026-10-27 by the orchestrator that ran the foundation chain (Waves 1–9). This file is your whole memory: read
it, then `docs/waves/PLAN.md` (header + **Fleet backlog**), `docs/PRD.md`, `docs/TDD.md` (skim; the lead and workers read
the sections they need) and `docs/design/feedback-round-1.md`. Your role contract is `~/.claude/skills/wave/roles/mother.md`.
The lead's is `roles/lead.md`, the workers' is `roles/worker.md`.

## Mission

Build Iris R1–R5 (PRD §Release plan) on the foundation that Waves 1–9 left, as an endless, self-driving loop:
backlog item → wave → lead → workers → merged, green, deployed → next. Iris is the owner's voice channel into his
agent estate: a phone memo is recorded in 10 s segments, then transcribed, routed (journal / Hermes / herdr tab / Chat),
acted on and notified through a Live Activity and APNs. There is one user, the owner.

## State (2026-10-27 evening)

- `iris-server` is **live on the mini** (`com.jkrumm.iris`, a deploy poller that auto-deploys a CI-green `master`).
  `make smoke` passes a real memo end to end in about 10 s. The trace is in HyperDX. The log Notifier stands in for APNs.
- The monorepo has the contracts (`contracts/`, `make check-contracts`), the Apple scaffold (XcodeGen, 4 targets, 4
  packages, `apple.yml` on the hosted `xcode-27` image), the Swift rule + vendored skills + the `apple-dev` skill, the
  Iris rules and skills, and the CLI verification harness (`make sim/run-sim/screenshot/ui-snapshot`, `scripts/mbm`).
- The design is reviewed. Round 1 mockups are approved with changes (`docs/design/feedback-round-1.md`, binding).
- `make check` is green, and CI is green on both workflows.

## Owner constraints right now

- **No paired iPhone until the owner is home (a few days).** Spikes S1–S3 and every device exit check wait.
  Start with the backlog items that need no phone (0, 4, 6, 7; PLAN.md says so). The simulator-testable parts of
  1–3 and 5 can go earlier if the queue runs dry.
- **Apple Developer Program enrollment is pending (~2026-10-28).** Until then: no APNs to real devices, no TestFlight,
  and signing for the simulator only (`CODE_SIGNING_ALLOWED=NO`). When the owner reports enrollment, the 1Password items
  (APNs `.p8`, App Store Connect API key) get created via `ask-human.sh`.
- Owner standing rules (global CLAUDE.md + memory):
  - pushes, merges and deploys in his own repos are routine; never park work on him;
  - he answers only the four stop reasons in `roles/mother.md`;
  - public repo: no real hosts, IPs, tokens or emails in tracked files (`make guard` enforces it);
  - no MCP servers;
  - Iris is his only Swift project.
- **Owner reviews to schedule:** design round 2 (backlog 0) needs his look. Send rendered links (private `/img`
  presigned URLs, never in git) plus a local gallery opened on his MacBook
  (`rsync … iumac:/tmp/… && ssh iumac open …`, the pattern used for round 1). Keep building unchanged surfaces while
  he reviews. The **Chat mode** reading (a Hermes session with a no-side-effects system message) needs one confirmation
  when backlog 4 starts.

## Fleet shape and models

- **You (mother):** Opus, high effort. Long-horizon sequencing and verdicts across ten backlog items. Never read
  source.
- **Lead:** spawn with `RD_WAVE_MODEL=opus RD_ORCHESTRATED=1 rd wave iris '<prompt>'`. It owns briefs, review and the merge
  train, and review quality is what keeps a long fleet from drifting, which is why it is Opus. Workers run on the
  default (Sonnet) via `rd fan`. Raise a worker only for novel hard logic (e.g. the gapless segment recorder) and write
  why in the brief.
- **One active wave at a time** in PLAN.md. Turn backlog items into `## Wave 10 …`, `## Wave 11 …` sections with steps
  sized for one lead context. Flip status, keep **Left behind** honest.

## Lessons from the foundation chain (do not relearn)

- **`rd wave` blocked at startup** came from Claude's folder-trust prompt under an account that had never opened the repo.
  `iu`, `me` and `me2` are now trusted for `~/SourceRoot/iris`. Worktrees from `rd fan` live elsewhere and may trigger it
  again. If a spawn reports `agent_not_ready`, read the pane and accept the trust prompt for that path.
- **"Dangerous rm" prompts block subagents even under skip-permissions.** The watcher reports `blocked`. Read the pane
  (`herdr agent read <name> --source visible`) and answer it if the command is safe.
- **The `agw` MCP review/check sometimes stalls or fails** (xcodegen "Couldn't find current username" in the gateway
  sandbox). Use the `agw review` CLI and run `make check` directly; that's what Waves 4–9 did.
- **Orchestrated waves don't spawn their successor;** whoever owns the loop does. Run
  `wave-watch.sh` in the background, review the close-out + diff + CI, `rd close`, then spawn the next. Never leave a
  finished tab open or a wave waiting.
- `make run-sim` / `screenshot` leave the simulator booted, so run `xcrun simctl shutdown all` after.
- `tap` via `scripts/mbm` needs `--post-delay 2` to navigate reliably.
- (Wave 10) `rd merge` fails on a draft PR (`gh pr ready` first). The `agw review` CLI prints only the summary; findings are in
  `GET /api/jobs/<id>` `.job.result`. A contract change must carry the Swift `IrisCore` follow-up in the same brief.
- `wave-watch.sh` can time out silently: write its output to a file (`> /tmp/iris-wN-watch.txt`) and check `rd agents`.

## Carry-forward debt (assign it inside backlog items, don't let it rot)

- Wave 5: the production vs fakes composition is duplicated (`index.ts` / `compose-fakes.ts`); the `MEMO_NEEDS_ROUTE`
  category; `+faststart` on the concat; lint warnings.
- Wave 7: Live Activity client phases (recording/paused/uploading); `IrisCapture`/`IrisUI`/`IrisTelemetry` → `IrisCore`
  wiring; `POST /v1/telemetry` on the server; outbox segment-file deletion; crash-file protection class; `.xcstrings`.
- TDD amendments whenever a backlog item changes a design decision. The TDD must stay true.
- Housekeeping (backlog 10): delete the mockup images after R3.

## Progress log

- 2026-10-27: Wave 10 done (design round 2 + R2 routing core, deployed `cc19d4c`). Chat-mode reading confirmed by the owner via the
  `ask-human` dialog (Run clicked). Design round 2 owner review pending (gallery on the MacBook, links in the untracked `links.local.md`).
- Wave 11 done (`f5da34c` deployed): journal, herdr, typed memos, Chat (soft no-side-effects `system_message`; Hermes rewrites the
  `iris-chat` source to `api_server`, so `threads.kind` is the marker), agw `caller`. Backlog 4 / R2 server complete.
- Wave 12 (R3 server: threads API, search + filters, stats, telemetry relay, housekeeping) active.
- Owner reviewed design round 2 (`docs/design/feedback-round-2.md`, binding, wins over round 1): folded into the backlog
  (4b server flags + auto retries, 6 History, 7 conversations, 2 in-app recording banner + whole-memo outbox, 8 Mac rows).
  No further design round. No Hermes upstream patch: Iris owns chat data. The w12 lead was steered: threads detail from
  Iris's own memos, stats baselines per step+route with n.

- Wave 12 done (`482883d` deployed): threads API from Iris's own memos, FTS5 search + filters + `pinned`, stats with per-step-and-route
  medians and n, telemetry relay, Node 24 actions. Owner amended round 2: Pele for Mermaid (server-rendered SVG + PNG), speech-ready
  answer variant, Threads tab dropped (owner-confirmed), freed tab slot reserved for PRD §Later. All in the backlog.
- Wave 13 (server flags + auto retries + debt ∥ iOS History shell) active; Wave 14 sketched (Pele + speech ∥ detail/Stats/Settings/composer).
- Account quota is the fleet's real constraint: `iu`/`me` near their 7-day caps until 10-28 16:00 / 10-29 06:00. A refused spawn
  ("no Claude account has room") is retried every 10 min in the background; never spill.

- Wave 13 done (server `c39eb6a`, apple `225235e`): memo flags + soft delete/undo/purge, auto retries (2 s / 8 s), Wave 12 debt,
  iOS History shell (tabs, rows, chips, filter sheet, swipe, undo toast). Open owner detail, not a stop: "further right/left" is a
  second swipe button, not a second full-swipe threshold (native `.swipeActions`).
- Wave 14 (Pele + speech ∥ memo detail, Stats, Settings, composer) active; Wave 15 sketched (conversations + capture sim parts).

- **Open owner stop (spend), 2026-10-28 05:15:** Requesty balance exhausted (402). agw triage fails, so production hermes memos fail
  at `summarize` (journal/herdr use templates and are unaffected); the reviews' adversary angle is blocked too. Owner notified.
  After the top-up: `POST /retry {from: summarize}` on the memos that failed meanwhile, then `make smoke`.

## Next action

Watch the active wave's lead (`iris-w<n>`), verdict its close-out, `rd close`, write the next wave from the backlog
(after Wave 14: write Wave 15 in full (7 conversations + 2's simulator parts: in-app recording banner, whole-memo outbox);
then 5 and 8's simulator parts; device items when the owner is home), spawn, loop.
