# I5c fidelity: thread view and typed composer

Wave 18 I5 (owner feedback 2026-10-30, binding). Screens: the thread (`threads.html?v=thread`, `chat.html`), the typed composer and
its mode picker (`compose.html`). Method: render the mockup (`make mockups`, 402 x 874) and screenshot the app at the same width,
light and dark, on iPhone 15 / iOS 26.5 first (the owner's class), then iPhone 17 / iOS 27.0 (the snapshot pin). Spacing comes only
from `Theme.Spacing`; no literal was added.

Decisions that stay as built, because a later owner verdict (`feedback-reply-flow.md`, Wave 15 I5 / Wave 16 I4) beats the round-2
mockup: the question turn is a card in the accent tint, code uses the JetBrains Light / Dark colours (`CodeColors`), the reply bar
is one row of icons (keyboard, hold to talk, locked recording) instead of the mockup's "Hold to talk" pill, an `ExchangeDivider`
opens every exchange after the first, a quote is an accent rule on a quiet panel.

## Deltas

| Screen | Element | Mockup | App before | Fix |
|-|-|-|-|-|
| Thread | side margin of the document | 20 | 16 (`lg`) | `screenMargin` |
| Thread | gap between turns | 14 | 16 | `inset` |
| Thread | gap between nav bar and the route chip row | 14 | 8 | `inset` |
| Thread | chip row to title | 10 (14 gap, -4 title margin) | 8 | `cozy` |
| Thread | title to first turn | 14 | 8 + 16 = 24 | the stack gap only (`inset`) |
| Thread | speaker line to its content | 6 | 8 | `snug` |
| Thread | speaker avatar glyph | 12 pt | 11 pt | 12 pt |
| Thread | question card padding | 11 / 14 | 12 / 12 | `cardInsetVertical` 12, `cardInsetHorizontal` 14 (11 is not on the scale; 12 is the nearest role) |
| Thread | question text colour | ink2 | ink | `Ink.secondary` |
| Thread | answer body size | 16 on a 1.5 line | 15 | `callout` (16), line spacing 0.31 em |
| Thread | gap between blocks of an answer | 10 | 12 (`md`), Textual paragraphs 0.8 em | `cozy`, paragraph style 0.625 em above |
| Thread | gap between list items | 6 | 4 (Textual default 0.25 em) | `listItemSpacing` 0.375 em |
| Thread | code block radius | 6 (`radius-ctrl`) | 10 (`card`) | `Radius.control` |
| Thread | code size | 13 | 13.2 (0.882 of 15) | 0.8125 of 16 (13) |
| Thread | pending turn card padding | n/a (new) | 12 all | card roles 14 / 12, like the question card |
| Thread reply bar | side inset | 14 | 16 | `barInset` |
| Thread reply bar | gap between buttons | 10 | 12 | `barGap` |
| Thread reply bar | icon to timer gap in the pill | 10 | 12 | `cozy` |
| Thread | failure toast | n/a | a literal 96 pt bottom offset | sits in the bottom inset above the bar, `barGap` between |
| Composer | gap between blocks | 12 | 16 | `md` |
| Composer | field to counter | 12 | 8 | `md` |
| Composer | counter side padding | 6 | 4 | `snug` |
| Composer | counter to hint card | 18 (12 + 6) | 16 | `md` + `snug` below the counter |
| Composer | field card height | 176 (padded card) | 160 before padding = 184 | 176 applied after the padding |
| Composer | hint card padding | 10 / 14 | 12 / 12 | `cozy` / `cardInsetHorizontal` |
| Composer | Send button | tinted "arrow Send" | arrow only (iOS 26.5 draws it tinted, iOS 27 plain glass) | an arrow and the title as two views (a toolbar drops a `Label` title), `.borderedProminent` |

## Not fixed here

| Item | Why |
|-|-|
| Six mode chips wrap to two rows on a 402 pt phone (the mockup has four chips and a quiet Tab menu in one row) | Transcribe joined the modes after round 2; a one-row picker is a design change for the owner |
| Mode chips: height 34, side padding 13, 15 pt text | `ChoiceChips`, `FilterChip`, `ChipFlowLayout` are shared with History (w18-i5a), read-only for this group |
| Typed memo counter row has no trailing "Auto asks where it goes if unsure" and no language prefix | content, not spacing |
| Avatar glyph is a mic or keyboard by how the turn was made, and the time line says "voice 38 s" / "typed" | the thread model does not carry the capture source |
| Long-press record sheet (`RecordModeSheet`) is chips plus a summary line, the mockup (`record.html?v=mode`) is a list of options with icons and a running-tab section | a redesign, not a spacing fix; stays as built, listed for the owner |
| The thread shows the global "Record" accessory under the reply bar | `RootView`'s tab accessory, outside this group's files; the mockup has none |
| Mockup pins the bar 26 pt above the screen bottom | the app keeps the bar in the safe area (`sm` below it); the glass floating dock is the shell's |

## Screenshots

`docs/design/fidelity/i5c/`, 2x, fake stack (`-IrisFakeCapture`), the "Chats" thread of the sample data: `before-*` the batch
branch at its start, `after-*` this branch; `ios26` is iPhone 15 / iOS 26.5, `ios27` is iPhone 17 / iOS 27.0. The thread crops show
the same spots of the same conversation (the list rhythm, the code block, the question card, the reply bar).
