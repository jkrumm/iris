import SwiftUI

/// The one spacing scale. Views never carry a spacing literal: they take a step or a role from here.
///
/// The steps are the 2/4/8-based values the mockups use (`docs/design/mockups/*.css`, `--space-*` plus the
/// literal paddings and gaps of the round-1/2 pages); `xs…xl` are the basalt tokens, the rest fill the gaps
/// between them. The roles name where a step is used, so a value changes in one place.
extension Theme.Spacing {
  // MARK: Steps (pt)
  public static let hair: CGFloat = 2
  public static let tick: CGFloat = 3
  public static let snug: CGFloat = 6
  public static let cozy: CGFloat = 10
  public static let inset: CGFloat = 14
  public static let gutter: CGFloat = 20

  // MARK: Roles
  /// Leading/trailing margin of a screen's content: title, section labels, rows, chip rows.
  public static let screenMargin = gutter
  /// Gap above a section label, and below it before the first row.
  public static let sectionTop = inset
  public static let sectionBottom = snug
  /// Large title: space above and below it.
  public static let titleTop: CGFloat = 18
  public static let titleBottom = snug
  /// A list row: vertical padding, gap between its columns, gap between its lines.
  public static let rowVertical = md
  public static let rowColumnGap = md
  public static let rowLineGap = tick
  /// Chips: gap between them in a row, padding inside one.
  public static let chipGap = snug
  public static let chipInsetHorizontal = md
  /// Chip height: the quick-filter row, and the larger chips of the filter sheet (`.fc` in `history.html`).
  public static let chipHeight: CGFloat = 30
  public static let chipHeightLarge: CGFloat = 36
  /// Space between the filter row and the section label under it is the section's own top; the row adds this above.
  public static let chipRowTop = sm
  /// A bottom sheet's side and bottom inset (`.fsheet`).
  public static let sheetInset: CGFloat = 18
  /// Floating bars (search, tab dock, record): side inset and gap between neighbours.
  public static let barInset = inset
  public static let barGap = cozy
  /// A card (`DetailCard`, panels): padding inside it.
  public static let cardInsetHorizontal = inset
  public static let cardInsetVertical = md
}
