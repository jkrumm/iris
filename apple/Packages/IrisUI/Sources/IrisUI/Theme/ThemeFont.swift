import SwiftUI

extension Theme {
  /// The basalt type scale. Each role keeps its basalt point size at the default Dynamic Type
  /// setting and scales with the user's preference relative to a matching system text style.
  public enum TextRole: CaseIterable, Sendable {
    case nano, micro, caption, footnote, subheadline, callout, body, title3, kpi, title, display

    var baseSize: CGFloat {
      switch self {
      case .nano: CGFloat(BasaltTokens.TextSize.nano)
      case .micro: CGFloat(BasaltTokens.TextSize.micro)
      case .caption: CGFloat(BasaltTokens.TextSize.xs)
      case .footnote: CGFloat(BasaltTokens.TextSize.sm)
      case .subheadline: CGFloat(BasaltTokens.TextSize.md)
      case .callout: CGFloat(BasaltTokens.TextSize.lg)
      case .body: CGFloat(BasaltTokens.TextSize.xl)
      case .title3: CGFloat(BasaltTokens.TextSize.h2)
      case .kpi: CGFloat(BasaltTokens.TextSize.kpi)
      case .title: CGFloat(BasaltTokens.TextSize.h1)
      case .display: CGFloat(BasaltTokens.TextSize.display)
      }
    }

    var textStyle: Font.TextStyle {
      switch self {
      case .nano, .micro: .caption2
      case .caption: .caption
      case .footnote: .footnote
      case .subheadline: .subheadline
      case .callout: .callout
      case .body: .body
      case .title3: .title3
      case .kpi: .title2
      case .title: .title
      case .display: .largeTitle
      }
    }
  }
}

private struct ThemeFontModifier: ViewModifier {
  let role: Theme.TextRole
  let weight: Font.Weight
  @ScaledMetric private var size: CGFloat

  init(role: Theme.TextRole, weight: Font.Weight) {
    self.role = role
    self.weight = weight
    _size = ScaledMetric(wrappedValue: role.baseSize, relativeTo: role.textStyle)
  }

  func body(content: Content) -> some View {
    content.font(.system(size: size, weight: weight))
  }
}

extension View {
  /// Applies a basalt type-scale role, scaled by Dynamic Type.
  public func themeFont(_ role: Theme.TextRole, weight: Font.Weight = .regular) -> some View {
    modifier(ThemeFontModifier(role: role, weight: weight))
  }
}
