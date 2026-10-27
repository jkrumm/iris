# Iris — UI mockups (round 1)

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

`make mockups` regenerates `tokens.css` and all 23 PNGs into `renders/` (headless Chrome, device-sized
viewport). The PNGs are gitignored. They were uploaded with `imgcli private` as presigned links (7 days
maximum); the repo is public, so the links are not tracked. They live in the untracked
`links.local.md` next to this file; re-issue with `imgcli private <png> --expires 7d`.

## Open design questions for the review

- **Needs-route in History:** a tinted row at the top (shown) versus a badge on the tab bar only.
- **Live Activity buttons:** Play / Reply / Open on done is three; a 4 KB payload is no issue, the width is.
- **Record screen mode row:** four chips fit at 402 pt; more running tabs go behind the tab chip's sheet.
- **Cost on the Lock Screen:** shown in the done state's subline (`$0.047`). Drop it if it reads as noise.
