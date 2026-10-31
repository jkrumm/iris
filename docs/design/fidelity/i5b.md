# Fidelity pass i5b: memo detail and route sheet (Wave 18 I5)

Reference: `docs/design/mockups/detail.html` (`?v=done|steps|cost|failed`, light and dark; renders `r2-detail-*`) and, for the route
sheet, which has no page of its own, the filter sheet of `history.html?v=filter-sheet` (the same sheet recipe: label, chips, one
prominent button). Values are points on the 402 pt screen. Spacing comes from `Theme.Spacing` only.

**Binding feedback wins over the render where they differ** (`feedback-round-2.md`, written after the r2 renders): player is
play/pause left, scrubbable timeline, one 10 s-back icon right, no speed; waterfall bars span the card like a bottom border, one
`duration · cost` chip per step, no separate Cost row; bottom actions icon-only. Those render differences are not deltas.

## Fixed

| Screen | Element | Mockup | App before | Fix |
|-|-|-|-|-|
| Detail | content side margin | 20 | 16 (`lg`) | `screenMargin` |
| Detail | gap between sections | 14 | 16 (`lg`) | `sectionTop` |
| Detail | gap from nav bar to the route chip | 20 | 19 measured on iPhone 15 / iOS 26.5 (`sm` plus the bar's own inset) | none: already matches; a `gutter` try gave 31 and was reverted |
| Detail | route chip row to headline | 10 | 8 | `cozy`; headline to detail text stays 8 |
| Detail | card inner padding (player, route card, transcript, reply) | 14 horizontal, 12 vertical | 12 all round | `cardInsetHorizontal` / `cardInsetVertical` |
| Detail | waterfall summary row | padding 14 / 12 | 16 / 12 | card insets; the gap stays `sm` so "Total" lines up with the step titles below it (a `cozy` try misaligned them by 2 pt and was reverted) |
| Detail | waterfall step rows | horizontal 14 | 16 | `cardInsetHorizontal` |
| Detail | bottom actions gap | 10 | 12 | `barGap` |
| Detail | failure toast | side margin 20, sits above the actions | overlay with a literal `96` bottom padding | toast joins the bottom safe-area inset above the actions, `screenMargin`; the literal is gone |
| Route sheet | content margin | 20 (sheet 18 + label 4 = 22) | 16 | `screenMargin` |
| Route sheet | gap between groups | 12 (10 + 2) | 16 | `sectionTop` (14) |
| Route sheet | gap above the submit button | 18 | 16 | `sectionTop` + `xs` = 18 |
| Detail | "Route to …" button on a parked memo | `accent-fill` | system `tint` (the lighter accent, visible in dark) | `.tint(Theme.Accent.fill)` |
| Route sheet | submit button fill | `accent-fill`, `on-accent` label | system `tint` (the lighter accent) | `.tint(Theme.Accent.fill)` |
| Route sheet | tab rows | 14 / 12 | 12 all round | card insets |

## Not changed, reported

| Where | Delta | Why |
|-|-|-|
| `DetailSectionLabel` (shared with Stats, Composer, Thread) | mockup `.label` is `faint` with `.04em` tracking; app is `muted`, no tracking | Shared component used by other groups' screens; changing it moves their snapshots. Needs one decision for all screens (w18-i5a/i5c). |
| `detailCard()` (shared) | none found | n/a |
| Detail | the mockup clamps the transcript to two lines | The app shows the whole transcript with a Copy button (device feedback 1: copy as text); a clamp would hide what the owner copies. |
| Detail | a Cost disclosure row, the median ghost boxes, axis and legend in the waterfall | Superseded by round 2 (one metric chip, bottom-border bars). |
| Detail | the 22 pt status circle and the "5 steps" / "Failed at summarize" label in the summary row | Wave 16 shipped "Total" with the chevron first; replacing it changes strings and the UI test selectors. Left for the owner's call. |
| Route sheet | the mockup sheet has a 21 pt title row with a trailing Reset; the app uses the system inline title and Cancel | System navigation bar, deliberately native. |

## Found on both simulators, not mine to fix

| Where | Observation | Owner |
|-|-|-|
| Detail, thread | On iPhone 15 / iOS 26.5 the Record accessory stays on screen under the bottom actions although the tab bar is hidden (AGENTS.md says detail and thread have no record control). The same on the pinned iPhone 17 / iOS 27.0 (`ios27-done-light.png`). | `RootView` / `RecordAccessory` (not in this group) |

## Screenshots

`docs/design/fidelity/i5b/` (2x, pinned iPhone 17 / iOS 27.0, fake stack, German simulator locale): `ios27-done-light`, `ios27-done-dark`,
`ios27-failed-dark` (waterfall open), `ios27-needsroute-light` (route card), `ios27-sheet-light` (route sheet). The iPhone 15 / iOS 26.5 run
was judged first and showed the same layout, with the two exceptions fixed above (the reverted tries). The "before" for the changed
components are the tracked IrisUI snapshots at the base commit (`Tests/IrisUITests/__Snapshots__`, see the PR diff of the re-recorded images).
