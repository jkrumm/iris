import SwiftUI

/// How a memo's Details are drawn. The iPhone's sheet reads the basalt type roles and card insets; the Mac's popover is a desktop
/// surface, where those read oversized, so it sets .desktop and the same views draw in the desktop type scale and tighter insets.
public enum DetailsDensity: Sendable {
  case phone
  case desktop
}

extension EnvironmentValues {
  /// The density MemoDetailsContent, StepWaterfall and IDValueField draw in; the iPhone's by default.
  @Entry public var detailsDensity: DetailsDensity = .phone
}

/// The sizes that differ between the densities.
struct DetailsMetrics {
  let insetHorizontal: CGFloat
  let insetVertical: CGFloat
  /// The column the step icon and the summary's chevron sit in.
  let iconWidth: CGFloat
  let iconSize: CGFloat
  let chevronSize: CGFloat
  let trackHeight: CGFloat
  let idPadding: CGFloat

  init(_ density: DetailsDensity) {
    switch density {
    case .phone:
      insetHorizontal = Theme.Spacing.cardInsetHorizontal
      insetVertical = Theme.Spacing.cardInsetVertical
      iconWidth = 22
      iconSize = 17
      chevronSize = 13
      trackHeight = 3
      idPadding = Theme.Spacing.md
    case .desktop:
      insetHorizontal = Theme.Spacing.cozy
      insetVertical = Theme.Spacing.snug
      iconWidth = 16
      iconSize = 13
      chevronSize = 11
      trackHeight = 2
      idPadding = Theme.Spacing.snug
    }
  }
}

extension View {
  /// The iPhone's role on the phone, the Mac's on the desktop.
  func detailFont(_ phone: Theme.TextRole, mac: Theme.MacTextRole, weight: Font.Weight = .regular) -> some View {
    modifier(DetailFontModifier(phone: phone, mac: mac, weight: weight))
  }
}

private struct DetailFontModifier: ViewModifier {
  let phone: Theme.TextRole
  let mac: Theme.MacTextRole
  let weight: Font.Weight
  @Environment(\.detailsDensity) private var density

  func body(content: Content) -> some View {
    switch density {
    case .phone: content.themeFont(phone, weight: weight)
    case .desktop: content.macFont(mac, weight: weight)
    }
  }
}
