# Design fidelity (Wave 18 I5)

The owner's feedback of 2026-10-30: the app drifted from the design renders "at many, many places". Each screen group lists
every spacing, alignment, type and colour delta between the mockup (`docs/design/mockups/*.html`, round 2 wins) and the
app, and what was done about it. Spacing values come from the one scale, `Theme.Spacing` (`IrisUI/Theme/Spacing.swift`).

## Method

1. Render the mockup (`make mockups`, PNGs in the gitignored `docs/design/renders/`) and screenshot the app at the same size,
   light and dark, on the owner's phone class (iPhone 15 / iOS 26.5, `make sim run-sim screenshot SIM_NAME="iPhone 15" SIM_OS=26.5`)
   and on the pinned iPhone 17 / iOS 27.0. iOS 26 renders glass and bars differently from 27: judge the 26.5 shot first.
2. Write the deltas as a table (screen, element, mockup value, app value, fix) in `<group>.md`.
3. Fix them from the scale; re-record the snapshots that move (`RECORD=1 make snapshots`) and look at the new images.
4. Keep at most 8 PNGs per group in `<group>/`, 2x downscaled.

A value that is not on the scale is added to `Spacing.swift` with the mockup it comes from, never typed in a view.

## Groups

| Group | Screens | Doc |
|-|-|-|
| History | list, top of the screen, rows, day sections, filter chips, filter sheet, toast, bottom bars | [history.md](history.md) |
