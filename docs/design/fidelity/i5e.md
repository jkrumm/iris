# I5e fidelity pass: Stats, Settings, Diagnostics

Group i5e of Wave 18 I5. Reference: `mockups/stats.html` (`r2-stats-day-*`, `r2-stats-week-dark`) and `mockups/settings.html`
(`r2-diagnostics-*`, the only Settings page the mockups draw; the Settings root, Outbox, Playback and Microphone groups
follow its card, label and footnote rules). Values are points (the mockup's CSS px at 402 pt).

Pictures (iPhone 15 / iOS 26.5, 2x, `i5e/`): `before-*` and `after-*` for Stats (light), Settings (light) and Diagnostics (dark).

Method: UI-test screenshots (a throwaway walk, not committed) on iPhone 15 / iOS 26.5 (the owner's phone class) first, light
and dark, against the mockup renders. "Before" is the Wave 17 app (batch-1); "After" the screens of this PR.

## Stats

| Element | Mockup | App before | Fix |
|-|-|-|-|
| Title | `h1` 30 bold under the status bar: 18 above, 10 below (top of the title ~80 pt) | native large title under an empty nav bar, ~36 pt lower | nav bar hidden, `ScreenTitle` (`titleTop` 18) in the content |
| Side margin | 20 | 16 (`lg`) | `screenMargin` |
| Gap between blocks (segment, range, tiles, chart, trends) | 10 | 16 | `cozy` |
| Tiles gap | 8 | 8 | none |
| Tile padding | 11 / 12 | 12 / 12 | none (the scale has no 11) |
| Memos tile caption | good green when it rose, with `▲` | muted, no arrow | `isRise` on `StatsReport.Tile`, caption in `Status.good`; arrow not added (the text is unit-tested) |
| Chart card padding | 14 top, 14 sides, 10 bottom | 16 all round | `inset` / `cardInsetHorizontal` / `cozy` |
| Chart title | 15 semibold ink, no caps | uppercase 12 muted label | `subheadline` semibold, primary |
| Chart subtitle | "Stacked by route, per day. Today is partial." 12 muted, 1 below the title | missing | added, `hair` below the title (day and week text) |
| Trends footnote | "Change against the 7 days before." 12 faint, 4 below the card, 4 inset | missing | added in `VStack(spacing: xs)` with the card; week text "Average per week over 8 weeks." |
| Tile set | Memos / Audio / Cost | Memos / Busiest / Cost · 56 d | not changed: a product decision after the round-2 render, not drift |

Not owned by i5e, so reported, not edited (`TrendRow`, `VolumeChart` are not in the owned list):

| Element | Mockup | App | Needed |
|-|-|-|-|
| Trend row padding | 9 / 14 | `sm + 1` / `lg` (16) | `rowVertical`-like 9 does not exist in the scale; horizontal should be `cardInsetHorizontal` |
| Trend row name column | 78 | 88 | control width, set to 78 |
| Legend | name + route total ("Hermes 14"), gap 12 | name only, gap 16 | add totals, gap `md` |
| Chart readout | `Tue 27 · 6` then coloured counts (all four routes) | counts for routes with data only | none, kept |

## Settings (root) and Diagnostics

The native `List` (iOS 26 capsule rows, 17 pt section titles, 16 pt row insets) is replaced by the render's flat cards.

| Element | Mockup | App before | Fix |
|-|-|-|-|
| Root title | as Stats | native large title, ~36 pt low | hidden nav bar, `ScreenTitle` |
| Diagnostics title | large title below the glass back button, 20 inset like the cards | inline title (a native large title would sit at 16, off the 20 margin) | inline bar, `ScreenTitle` in the content |
| Diagnostics memo row | "Memo", headline below in 13 muted, time and chevron trailing | blue system menu label, truncated mid-text | `Menu` with the same row layout |
| Status bar | n/a (the render has no scrolling) | content printed over the clock when scrolled under a hidden nav bar | `statusBarScrim()`: the screen background in the status-bar region |
| Group label | 12 semibold uppercase, 4 inset, 8 above the card | 17 semibold title case, system inset | `DetailSectionLabel` + `xs` / `sm` |
| Card | panel fill, 0.5 pt border, radius 10 | system rounded rows (radius ~26 on iOS 26) | `detailCard()` |
| Row | 13 / 14 padding, 12 column gap, 15 title, 13 muted detail, hairline dividers | system 11 / 16, 17 title | `settingsRow()` (`rowVertical` 12 / `cardInsetHorizontal` 14), `subheadline` / `footnote` |
| Footnote | 12 faint, 8 below the card, 4 inset | 13 muted system footer | `caption`, `Ink.faint`, `sm` / `xs` |
| Gap between groups | 18 | system (~35) | `gutter` (20) |
| Server status | muted 13 | secondary 17 | `footnote`, `Ink.muted`, dot gap `snug` |
| Toggle | `status-good` | system green | `.tint(Status.good)` |
| Trace card | 14 padding, 10 between box and buttons | 12 | `cozy` |
| Outbox swipe | n/a | swipe-to-discard (List only) | inline Retry / Discard buttons for every discardable item, context menu kept |

## Deltas left open

| Element | Mockup | Why not fixed |
|-|-|-|
| Row vertical padding 13, tile padding 11, group gap 18, list row `sm + 1` 9 | 13 / 11 / 18 / 9 | missing from `Theme.Spacing` (owned by w18-i5a); nearest steps used: 12 / 12 / 20 / (TrendRow untouched) |
| Diagnostics copy | "Copy trace id" + "Memo id" buttons, trace id shown | the app copies the memo id; a behaviour change, not a visual one |
| Diagnostics "Lock Screen" group (hide cost) | toggle and preview | a feature that is not built |
| Route configuration review screens | n/a | review-only surface behind `-IrisRouteConfigReview`; only its spacing literals moved to `hair`; still a `List` |
| Large-title tracking | -0.01 em | no tracking role |
