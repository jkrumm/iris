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
  /// The part of a chip's 44 pt tap area that lies outside its drawn 30 pt: the row removes it from the space around it.
  public static let chipTapOverhang = (tapTarget - chipHeight) / 2
  /// A bottom sheet's side and bottom inset (`.fsheet`).
  public static let sheetInset: CGFloat = 18
  /// Floating bars (search, tab dock, record): side inset and gap between neighbours.
  public static let barInset = inset
  public static let barGap = cozy
  /// A floating bar's height and the diameter of its round buttons (`.searchbar`, `.fbtn` in `history.html`).
  public static let barControlSize = tapTarget
  /// The smallest area a control answers taps in (Apple's 44 pt); a smaller visual is padded to it with a content shape.
  public static let tapTarget: CGFloat = 44
  /// A card (`DetailCard`, panels): padding inside it.
  public static let cardInsetHorizontal = inset
  public static let cardInsetVertical = md
}

/// The Mac menu-bar popover (`mac.html`, variant `menu`: `.menu`, `.menu .top`, `.menu .m`, `.menu .ln`, `.menu .st`).
extension Theme.Spacing {
  /// `.menu` width (340) plus room for the German strings; every page of the popover is this wide.
  public static let menuWidth: CGFloat = 360
  /// Height of the History and Settings pages (the home page fits its content).
  public static let menuPageHeight: CGFloat = 520
  /// `.menu` padding and the gap between its children.
  public static let menuInset = md
  public static let menuGap = hair
  /// `.menu .top` padding: 4 above, 10 below, 6 at the sides.
  public static let menuHeaderTop = xs
  public static let menuHeaderBottom = cozy
  public static let menuHeaderSide = snug
  /// `.menu .m`: padding 9 / 10, column gap 10, line gap 1, radius 12.
  public static let menuRowVertical: CGFloat = 9
  public static let menuRowHorizontal = cozy
  public static let menuRowLineGap: CGFloat = 1
  public static let menuRowRadius: CGFloat = 12
  /// `.menu .ln`: padding 7 / 10, radius 8.
  public static let menuLineVertical: CGFloat = 7
  public static let menuLineRadius: CGFloat = 8
  /// `.menu hr`: 6 above and below and at the sides.
  public static let menuDivider = snug
  /// `.menu .st`: padding 6 / 10 / 2.
  public static let menuFooterTop = snug
  public static let menuFooterBottom = hair
  /// A Mac chip's height (the quick-filter row in the popover's history page).
  public static let menuChipHeight: CGFloat = 26
  /// The Record button's padding (`.btn.sm`).
  public static let menuButtonVertical = snug
  public static let menuButtonHorizontal = cozy
}

/// The Mac recording panel (`mac.html`, variant `panel`: `.panel`, `.panel .hd`, `.lvl`, `.ft`, `.btn`).
extension Theme.Spacing {
  /// `.panel` is 360 wide in the mockup; the real strings (German, a long microphone name) need more, and nothing may clip.
  public static let panelWidth: CGFloat = 420
  /// `.panel` radius 26, padding 16 / 18, gap 12.
  public static let panelRadius: CGFloat = 26
  public static let panelVertical = lg
  public static let panelHorizontal: CGFloat = 18
  public static let panelGap = md
  /// `.panel .lvl` height.
  public static let panelLevelHeight: CGFloat = 38
  /// `.panel .btn` height 34, padding 14; `.panel .ft .chip` height 30.
  public static let panelButtonHeight: CGFloat = 34
  public static let panelButtonInset = inset
  public static let panelChipHeight = chipHeight
}
