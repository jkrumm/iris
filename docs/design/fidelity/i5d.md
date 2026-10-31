# I5 fidelity, group i5d: take screen, banner, record accessory, Live Activity, notification card

Reference: `docs/design/mockups/record.html` (`r2-record-*`), `lockscreen.html`, `island.html`, `notification.html` (+ `la.css`), rendered
with `make mockups`. App: the pinned iPhone 17 / iOS 27.0 simulator (`make run-sim`, a take started from the record accessory) and the
IrisUI snapshot images. Spacing comes from `Theme.Spacing` only; where the mockup's value has no step, the nearest step is used and the
gap is listed under "Missing from the scale".

The Live Activity, the Dynamic Island and the notification content extension cannot be rendered by the simulator (device checklist
rows); their before/after is the IrisUI snapshot (`LiveActivitySnapshotTests`, the island drawn by `IslandMock`) plus the mockup.

## Evidence (iPhone 17 / iOS 27.0, 2x downscaled, in `docs/design/fidelity/i5d/`)

| What | Before | After |
|-|-|-|
| Take screen, dark | `take-dark-before.png` | `take-dark-after.png` |
| Take screen, light | `take-light-before.png` | `take-light-after.png` |
| Compact banner, light | `banner-light-before.png` | `banner-light-after.png` |
| Lock Screen card, recording, dark (snapshot) | `lock-recording-dark-before.png` | `lock-recording-dark-after.png` |

The banner now sits at `barInset` (14) on both sides while History's search bar still sits at 16 on this base: they align once
History adopts `barInset` (w18-i5a).

iPhone 15 / iOS 26.5 (`i5d-15`, a clone of the device list): the app built and ran, but `mbm tap` on `record.start` (three tries,
longer delays) never opened a take there, so the take screen and banner were judged on iOS 27 only; the code is the same SwiftUI
(no iOS-version branch in the owned files). On 26.5 the Record accessory renders as a flat capsule above the tab bar over the rows,
as on 27. Not investigated further; worth one device look in D1.

## Deltas

| Screen | Element | Mockup | App before | Fix |
|-|-|-|-|-|
| Take | side margin | 20 | 16 (`lg`) | `screenMargin` (20) |
| Take | top of the content row | 64 incl. status bar (button top at the safe area) | 16 below the safe area | `hair` (2) |
| Take | top row to mode chip | 18 | 24 (`xl`) | `gutter` (20) |
| Take | mode chip padding | 0 13, 34 high | 12 / 6 literals of `md` / `snug` | `chipInsetHorizontal` / `snug`, own `modeChip` view |
| Take | timer | 76 pt light, tracking -.02 em | 72 pt, no tracking | 76 pt, tracking -1.5 |
| Take | level waveform | 120 high, bars 4 wide, gap 4 | 96 high, bars 3 wide, gap 3 (`tick`) | 120 high, bar width and gap `xs` (4) |
| Take | timer to wave | 28 | 24 + frame slack | `xl` (24), group centred between the chips and the mic row |
| Take | mic chip to controls | 18 | 24 + 12 bottom padding = 36 | one group, `gutter` (20) |
| Take | controls gap | 26 | 26 literal | `xl` (24) |
| Take | hint under the controls | "Stop sends the take · × discards it", caption, faint, 16 below the controls | missing | added (`TakeScreenLabels.hint`) |
| Take | bottom | controls + hint end at the safe area | 28 above it | `hair` |
| Take | stop button | `status-bad` at 82 % | solid `status-bad` | `Theme.Status.bad` at 0.82 |
| Banner | side margin | follows the search bar (`barInset`) | 16 (`lg`) | `barInset` (14) |
| Banner | gap below | 10 | 8 (`sm`) | `barGap` (10) |
| Banner | leading padding | 14 (`cardInsetHorizontal`) | 16 | `inset` (14) |
| Banner | stop button | `status-bad` at 82 % | solid | 0.82 |
| Lock Screen | card padding | 14 top, 16 sides and bottom | 16 all round | top `inset`, rest `lg` (widget) |
| Lock Screen | timer | 44 pt light, tracking -.01 em | 38 pt | 44 pt, tracking -0.44 |
| Lock Screen | timer to input chip | 14 | 12 | `inset` |
| Lock Screen | title (processing, needs route, done, failed) | 18 pt (`text-xl`) 600 | 16 pt (`callout`) | `body` (18) semibold |
| Lock Screen | title to subline (done) | 2 | 6 (`snug`) | `hair` |
| Lock Screen | mark to headline (done, failed) | 12 | 8 | `md` |
| Lock Screen | subtitle to dashes (processing) | 12 | 10 (`cozy`) | `md` |
| Lock Screen, island | buttons | 38 high, `status-bad` at 85 % for Stop | 36 high, solid | 38 (`ActivityControlLabel.height`), 0.85 |
| Notification | order | headline, then the route chip | chip, then headline | swapped |
| Notification | headline | 21 pt (`text-h2`) bold | 15 pt semibold | `title3` bold |

## Not fixed (features the mockups show that the app does not have, or a design call)

- Take: the mode row (four chips plus the tab chip), the settings gear (top right), the keyboard button beside the microphone chip, the
  "77 of 77 segments uploaded · 2.4 MB" line, the "Car detected / rule applied" card, the "min" suffix on the timer. The app shows the one
  mode the take started with (`TakeController` is not in this group and has no mid-take mode switch).
- Record accessory: the mockup's round blue microphone button in the dock; the app's is the system `tabViewBottomAccessory` (Wave 16
  decision), a capsule bar of which only the label is ours. Left as is.
- Compact banner: no mockup exists (`feedback-round-2.md` describes it in words); it takes the floating-bar roles.
- Lock Screen: the header (app icon + "Iris" left, route chip with a dot right, "now"), the step labels under the dashes, the done
  subline `38 s · $0.047 · 3 tasks`, Reply and Open beside Play, the waveform beside the timer. The Live Activity carries no cost, task
  count or step names (`ContentState`, server contract), so these are not drift but unbuilt.
- Notification card: the system draws the app header and the action buttons; the summary list, player and the `38 s` / `$0.047` chips
  have no payload to come from.

## Missing from the scale (for w18-i5a)

| Value | Where the mockup uses it | Used instead |
|-|-|-|
| 18 | take: top row to chips and mic to controls; notification horizontal padding | `gutter` (20) / `lg` (16) |
| 26 | take: gap between the three controls | `xl` (24) |
| 28 | take: gap between the timer, wave and meter note | `xl` (24) |
| a control height role (34 chip, 38 button, 40 mic chip, 44 / 56 / 84 round buttons) | take, Live Activity | sizes are not spacing; they stay as frame sizes (`ActivityControlLabel.height` names the 38) |

## Open

- **Contrast:** Stop and the banner's Stop are `status-bad` at 0.82 / 0.85 with a white glyph, as in the mockup's red glass. Their contrast
  against the light background is lower than the solid red they replaced; not measured against WCAG here, left as the render has it.
