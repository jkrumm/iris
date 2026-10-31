# Iris — UI mockups (rounds 1 and 2)

Static HTML for the owner's review, before any screen is built in Swift (TDD §7 process). Colors, radii,
spacing and type sizes are the basalt-ui tokens, converted from `IrisUI/Theme` by
`mockups/gen-tokens.ts` into `mockups/tokens.css`, so the mockups and the app share one source. Glass (blur,
saturation, specular rim) is used only on floating controls; content stays flat. System chrome (Lock
Screen, Dynamic Island, notification, status bar) uses Apple's own shapes, not tokens.

Sample content is German and English and reuses the contract fixtures' memo (the Wochenplan memo, `$0.0471`
across five steps). Nothing here is real data.

## Surfaces

Open any page in a browser: `mockups/<page>.html?scheme=light|dark&v=<variant>`.

| Surface | Page and variant | Renders (`renders/`) |
|-|-|-|
| History (needs-route, working, failed, done rows; search, tab dock, record) | `history` | `history-light`, `history-dark` |
| Memo detail (player, step timeline with duration and cost, retry) | `detail?v=done\|failed` | `detail-light`, `detail-dark`, `detail-failed-dark` |
| Record (timer, level, mic picker with route rule, mode and tab picker, stop) | `record?v=take\|mic\|mode` | `record-light`, `record-dark`, `record-mic-dark`, `record-mode-light` |
| Lock Screen with Live Activity | `lockscreen?v=idle\|recording\|processing\|done\|needs-route` | `lockscreen-idle`, `-recording`, `-processing`, `-done`, `-needs-route`, `-done-light` |
| Dynamic Island, compact and expanded, four states | `island` | `island` |
| Notification card (content extension and actions) | `notification?v=done\|needs-route` | `notification-done-dark`, `notification-done-light`, `notification-needs-route-dark` |
| Mac (floating panel, menu-bar window, native notification) | `mac?v=panel\|menu\|notify` | `mac-panel-light`, `mac-panel-dark`, `mac-menu-dark`, `mac-notify-light` |

iPhone surfaces render at 402 x 874 pt (iPhone 17), the Mac at 1440 x 900, all at 2x.

## Renders and links

`make mockups` regenerates `tokens.css` and all PNGs into `renders/` (round 1: 23; round 2 adds `r2-*`, see below) (headless Chrome, device-sized
viewport). The PNGs are gitignored. Share one with `imgcli private <png> --expires 7d` (presigned, 7 days maximum); the repo is public, so
links are never tracked.

## Open design questions for the review

- **Needs-route in History:** a tinted row at the top (shown) versus a badge on the tab bar only.
- **Live Activity buttons:** Play / Reply / Open on done is three; a 4 KB payload is no issue, the width is.
- **Record screen mode row:** four chips fit at 402 pt; more running tabs go behind the tab chip's sheet.
- **Cost on the Lock Screen:** shown in the done state's subline (`$0.047`). Drop it if it reads as noise.

## Round 2

Applies `feedback-round-1.md` (binding). Same approach as round 1: static HTML on the generated basalt tokens, glass only on
floating controls, German and English content around the fixture memo, `?scheme=light|dark&v=<variant>`. Round-2 renders are
named `r2-*`; the round-1 PNGs of surfaces that changed were kept as the before picture until the screens shipped; they are no longer kept (Wave 17 H1), `make mockups` regenerates both rounds.
The Lock Screen pages did not change and keep their round-1 names. `mock.css` gained `.soft` (glass with almost no drop shadow)
and the markdown block `.mdx`; `mock.js` gained the icons and the shared four-tab dock (`<div class="dock" data-dock="...">`).

`make mockups` renders everything. The review gallery is a separate step:
`bun docs/design/gallery.ts` writes `renders/iris-mockups.html` (images linked from a sibling `iris-mockups/` directory;
the header comment has the rsync line). Presigned image links go only into the untracked `links.local.md`.

### Surfaces and renders

| Surface | Page and variant | Renders (`renders/`) |
|-|-|-|
| Memo detail | `detail?v=done\|steps\|cost\|failed` | `r2-detail-light`, `-dark`, `r2-detail-steps-light`, `-dark`, `r2-detail-cost-dark`, `r2-detail-failed-dark` |
| Settings → Diagnostics (new) | `settings?v=diagnostics\|copied` | `r2-diagnostics-light`, `-dark`, `r2-diagnostics-copied-dark` |
| Dynamic Island | `island?v=single\|two` | `r2-island`, `r2-island-two` |
| Notification card | `notification?v=done\|needs-route` | `r2-notification-done-dark`, `-light`, `r2-notification-needs-route-dark` |
| Mac | `mac?v=panel\|menu\|notify\|notify-reply` | `r2-mac-panel-light`, `-dark`, `r2-mac-menu-dark`, `r2-mac-notify-light`, `r2-mac-notify-reply-dark` |
| Record | `record?v=take\|mic\|mode\|chat` | `r2-record-light`, `-dark`, `r2-record-mic-dark`, `r2-record-mode-light`, `r2-record-chat-dark` |
| Chat mode, answered thread (new) | `chat` | `r2-chat-answer-light`, `-dark` |
| Typed memo composer (new) | `compose` | `r2-compose-light`, `-dark` |
| History, with filters (new) | `history?v=list\|filters\|filter-sheet` | `r2-history-light`, `-dark`, `r2-history-filters-light`, `-dark`, `r2-history-filter-sheet-dark` |
| Stats (new) | `stats?v=day\|week` | `r2-stats-day-light`, `-dark`, `r2-stats-week-dark` |
| Threads (new) | `threads?v=list\|thread\|hold` | `r2-threads-list-light`, `-dark`, `r2-threads-thread-light`, `-dark`, `r2-threads-hold-dark` |

### How each feedback item was applied

| Feedback | Applied as |
|-|-|
| Detail: less shadow on the bubbly buttons | `.soft` on the detail, Diagnostics and Chat screens: same blur and rim, drop shadow cut to a 1 px hairline |
| Detail: telemetry not shown by default | Steps and Cost are one-line disclosure rows. A thin strip under Steps shows the run at a glance and flags a slow step |
| Detail: scrubbable player, 10 s back | Waveform with a drag knob, elapsed and remaining time, a 10 s back button, play/pause, speed chip |
| Detail: waterfall, faster/slower than median, collapsed by default | One track for the whole run. Each bar starts where the previous ended. A dashed ghost box is the step's median from the same start, so a shorter bar is faster and a longer one slower. Tags say `typical`, `+39 % slower`, `-17 % faster` (more than 15 % off the median), with the median value; colour is never the only signal. Collapsed by default; `v=steps` is the open state. The failed memo opens it |
| Detail: trace id not visible | Removed from the memo, including the footer line. Lives in Diagnostics |
| Detail: cost | Collapsed row with the total; `v=cost` is the open state. The total step time now matches the sum of the steps (27.5 s; round 1 showed 29.4 s) |
| Diagnostics: trace id with copy | Memo picker, the 32-hex trace id (memo id without dashes), `Copy trace id`, a `Copied` state, and a memo-id copy |
| Settings: hide cost on Lock Screen | Toggle with a Lock Screen preview of the result, on the Diagnostics screen as briefed (see open questions) |
| Island: icon button for mic switch, keep pause | `micswap` icon button next to a pause icon button; Stop keeps the width |
| Island: two memos in a row | Compact split (pill plus a small circle), expanded recording with the previous memo as a status row, expanded done with the next memo's timer as a row |
| Notification: smaller, side by side | One row of three 38 pt capsules: Play / Reply / Open (Journal / Hermes / dotfiles on needs-route) |
| Mac: hotkey differs from dictation | Shown as `⌃⌥ I` in the panel and the menu (placeholder, see open questions) |
| Mac: Reply on the notification | Banner actions Play / Reply / Open; Reply expands into an inline text field with a mic button for a voice reply and send |
| Record: tab chip de-emphasized | The tab chip is an icon-only hairline chip with no glass; the mode sheet moves tabs under "A running tab · rarely needed" with the hint to say the project while talking |
| New: Chat mode | Mode row and sheet option; the Record screen in Chat explains "nothing is filed or run"; the answered thread is the question as the headline, the rendered answer, a Play button for the spoken version, follow-up by voice or text |
| New: typed fallback | Keyboard button next to the mic picker on Record opens the composer: mode chips, text, same routing hint, Send |
| New: History filters | Filter button beside search (badge = active filters), route and state chips on the list, a filter sheet with counts and a date range |
| New: Stats | Days / Weeks switch, three totals, stacked bars per route (hover readout shown inline), per-route trend rows with sparkline and change |
| New: Threads | List with route, turn count and last line; one thread as a rendered markdown document (typed and spoken turns marked); hold-to-talk bar and its holding state |

Stats colours: Hermes blue, Journal green, Chat violet, Tabs orange, checked with the dataviz palette validator in light and dark
(all checks pass). Series order is fixed.

### Open questions for the owner

- **Mac hotkey:** I don't know your dictation key. `⌃⌥ I` is a placeholder that avoids the common `⌥ Space` and `Fn`. Name the key to avoid, or pick one; the Mac settings should make it recordable.
- **Where the cost toggle lives:** the brief puts it on Diagnostics, the feedback says "a Settings toggle". It is a display preference rather than a diagnostic. I'd move it to a Settings root group next to the mic rules.
- **Side-by-side notification actions:** system notification actions always render as a vertical list. Side by side means buttons inside the content-extension card; this needs a device check (do they keep working with the card collapsed?). Fallback: the system list, as in round 1.
- **Two memos:** one Live Activity per memo (system-split island, shown here) versus a single queue activity. Showing the previous memo inside an expanded activity needs the activity to carry the other memo's state. Tendency: one per memo, drop the status row if it costs state.
- **Waterfall rules:** median over the last 30 memos per step and route, 15 % threshold, hidden until a step has at least five samples. The failed memo auto-expands. Say if you want the threshold or the window different.
- **Route colour for tab memos:** History dots show herdr as grey, Stats needs a distinct hue (grey fails the colour-blind check) and uses orange. Pick orange everywhere, or grey in lists and orange only in charts.
- **Typed-memo entry point:** the keyboard button beside the mic picker on Record. Alternatives: a long-press on the record button in History, or a button in the History search bar.
- **Stats as a dock tab:** four tabs plus Record fit at 402 pt. Alternative: a button in the History header and keep three tabs. Stats also shows cost; the Lock Screen toggle does not touch it.
- **Chat in the Threads list:** assumed Chat memos create threads like Hermes ones (violet route chip), and a Chat reply by hold-to-talk stays in that thread. Confirm.
- **Reply flow as built (Wave 15 I5): answered** by `feedback-reply-flow.md` (2026-10-29: good trajectory, Liquid Glass stays; reply bar as one row of icons, a more structured
  thread, JetBrains-style code colors, the composer holding with the keyboard up). The ten Wave 15 renders are superseded by the follow-up below.
- **Reply flow, follow-up look (Wave 16 I4), for the owner's async review:** does the built verdict read right? Simulator renders on the fake stack (iPhone 17, iOS 27.0), light then
  dark, from `scripts/reply-flow-shots.sh` (`ReplyFlowReviewUITests`). Private objects in the image store, not committed; links on request (`imgcli private-url <key> --expires 7d`).
  Keys are `private/<key>`, under `2026/10/`, light then dark:
  1. Thread: exchanges split by a hairline, question card in the accent tint, the answer with a heading, table cards, a JetBrains-colored code block and a quote; the reply bar in one row (keyboard · hold to talk · locked recording, mic with a lock). `ig2t53snsf5wkdcx.png` / `65f5xa8h6ajxnplh.png`
  2. Reply by text: the composer bound to the thread, Cancel and Send at the top. `6okerwb59o7ok00f.png` / `x2yqx4zvqvq04iyw.png`
  3. Text reply sent, pending bubble with step dashes: `gqshdpm58j8w6ngw.png` / `bjxhr18b2k5nsfgw.png`; the answer revealed: `sqmkz54io27i60r2.png` / `umgr4nevltvs2t5d.png`
  4. Voice reply (hold) sent, pending: `10otvl2w6bjpi966.png` / `tmah5ljkf61xecic.png`; answer revealed: `9fnti6ao2c3dbsi1.png` / `vqkirvmkdd2oz28e.png`
  5. Locked recording running (cross · timer · send): `o8mw1ptjsaq7w1q8.png` / `69bmmq1b4ny04t90.png`

  Not shown: the hold state (a finger cannot be held through a screenshot; the bar shows the timer and the release hint), and the composer with the software keyboard up (the headless
  simulator reports a hardware keyboard, so no keyboard is drawn; the field and Send stay reachable and the flow is asserted by the UI test). The code colors and their token table are in
  TDD §4 "Reply layout and code themes". Uploaded 2026-10-30 with a 7-day presign, so ask for fresh links after 2026-11-06.
- **Route configuration (Wave 17 I6), for the owner's async review:** answers "where is routing configured?" (`feedback-device-1.md` §3). Render only, nothing is built. Simulator renders on the
  fake stack (iPhone 17, iOS 27.0), light then dark, from `scripts/route-config-shots.sh` (`RouteConfigReviewUITests`); the screens exist in the app only under the launch argument
  `-IrisRouteConfigReview`. Private objects in the image store, not committed; links on request (`imgcli private-url <key> --expires 7d`). Keys are `private/<key>`, under `2026/10/`, light then dark:
  1. Settings → Routes, the overview: the server's three destinations with their status (Journal shown as not set up), and the audio route with its microphone rule. `z9i0l5eaxwh7r5id.png` / `2agzy42djip1qeo3.png`
  2. Herdr destination: what it does, how to send a memo there (spoken "tab <name>", the Tab record mode), the live tabs and their agent state. `5ypunicd0fhwqc5s.png` / `0mm0tk2bd4bvza1k.png`
  3. A destination the server has not set up (Journal): it says what the server lacks instead of offering a switch. `dcw2wn4sf4cywh8m.png` / `sc8ktc8byidevjfu.png`
  4. Audio routes: the connected route's microphone choice (the rule that exists today) and the routes seen before. `8wg5i1cpk9puytoq.png` / `marxo4c35hwog23c.png`

  Two things were both called "routes", so the screen keeps them apart: *destinations* (where a memo goes, decided by the server) and *audio routes* (which microphone, kept on the phone per route). Placement: a "Routes"
  row in Settings above Microphone. Rejected: a fifth dock tab (four plus Record already fill 402 pt, and Settings is where the feedback looked first) and a sheet from the route chip (the chip only appears on a memo, so it
  cannot be found in advance). Not shown: a destination that does not exist yet; the list is the server's fixed three (`hermes`, `journal`, `herdr`). The "Fake Headset" and "iPhone Speaker" names in the connected-now card
  come from the fake audio stack, and the "seen before" rows are sample data: the rule store keeps only a route's fingerprint, so listing earlier routes needs it to remember each route's name when its rule is set.
  Uploaded 2026-10-30 with a 7-day presign, so ask for fresh links after 2026-11-06.
  *Open question:* the destinations are server configuration (registered from `BRAIN_DIR` and `HERDR_SOCKET` at boot), so today the phone can only read them; that needs a new `GET /v1/destinations`. Is a read-only view enough, or should
  something here be editable, for example a fallback destination for a memo Iris is under 80 % sure about, instead of parking it at needs-route?
- **Not designed:** the later routing refinement for herdr-bound memos (orchestration queue, factory), and Settings beyond Diagnostics.

## Round 3: widgets (Wave 19 R2)

A new surface, rendered for the owner's async review (no blocking round). These are not HTML mockups: they are the snapshot PNGs of the real views, on the pinned simulator, in
`apple/Packages/IrisUI/Tests/IrisUITests/__Snapshots__/WidgetSnapshotTests/`. The system draws the container, corner radius, wallpaper and vibrant recoloring on a device; the
PNGs show what the widget puts in (Home Screen: 170 × 170 and 364 × 170 pt on the panel color, light and dark; Lock Screen: on a dark gradient, white ink).

| Widget and family | What to look at | Renders |
|-|-|-|
| Last memo, small | state line (icon and word in the state color), headline up to 4 lines, route chip and age at the bottom | `lastMemoSmall.<state>-light`, `-dark` |
| Last memo, medium | the same, plus a round record button on the right | `lastMemoMedium.<state>-light`, `-dark` |
| Record, small | one 72 pt microphone and the word "Record"; legible at distance (StandBy) | `recordSmall.record-light`, `-dark`, `standBy.record` |
| Last memo, Lock Screen | rectangular (state + two headline lines), inline (one line), circular (state glyph) | `lastMemoRectangular.<state>`, `lastMemoInline.<state>`, `circular.state-<state>` |
| Record, Lock Screen | circular microphone | `circular.record` |
| StandBy | the small widgets with no background on black | `standBy.last-memo-done`, `standBy.last-memo-needs-route`, `standBy.record` |
| Accented / vibrant | no state color, the accent group marked | `monochrome.*` |
| German | the same strings in German | `german.*` |

States (`<state>`): `no-data` ("Open Iris", the static state when the App Group is unavailable), `idle` ("Ready", a stale in-flight memo), `processing`, `done`, `needs-route`, `failed`.
Open questions for the owner: whether the medium widget should carry the record button (it is the only place a Home Screen user has both), and whether a failed memo should read as
red (it does in full color, and drops to the accent group in tinted and Lock Screen renderings).
