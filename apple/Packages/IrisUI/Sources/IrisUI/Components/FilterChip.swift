import SwiftUI

/// A capsule toggle for the quick filters and the filter sheet. The title arrives localized.
public struct FilterChip: View {
  private let title: String
  private let systemImage: String?
  private let isOn: Bool
  private let size: Size
  private let action: () -> Void

  /// `standard` is the original chip: footnote text, 8 pt above and below (the composer's mode picker, the route sheet).
  /// `compact` is History's quick-filter row (30 pt, footnote) and `regular` the filter sheet's (36 pt, subheadline); both
  /// draw that height but answer taps over ``Theme/Spacing/tapTarget``.
  public enum Size {
    case standard, compact, regular

    fileprivate var height: CGFloat? {
      switch self {
      case .standard: nil
      case .compact: Theme.Spacing.chipHeight
      case .regular: Theme.Spacing.chipHeightLarge
      }
    }
    fileprivate var font: Theme.TextRole { self == .regular ? .subheadline : .footnote }
    fileprivate var verticalPadding: CGFloat { self == .standard ? Theme.Spacing.sm : 0 }
    fileprivate var tapHeight: CGFloat? { self == .standard ? nil : Theme.Spacing.tapTarget }
  }

  public init(
    title: String, systemImage: String? = nil, isOn: Bool, size: Size = .standard, action: @escaping () -> Void
  ) {
    self.size = size
    self.title = title
    self.systemImage = systemImage
    self.isOn = isOn
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: Theme.Spacing.xs) {
        if let systemImage {
          Image(systemName: systemImage)
            .accessibilityHidden(true)
        }
        Text(verbatim: title)
          .lineLimit(1)
      }
      .themeFont(size.font, weight: .medium)
      .foregroundStyle(isOn ? Theme.Accent.onFill : Theme.Ink.secondary)
      .padding(.horizontal, Theme.Spacing.chipInsetHorizontal)
      .padding(.vertical, size.verticalPadding)
      .frame(minHeight: size.height)
      .background(isOn ? Theme.Accent.fill : Theme.Surface.subtle, in: .capsule)
      .overlay { Capsule().strokeBorder(Theme.Surface.border, lineWidth: isOn ? 0 : 0.5) }
      .frame(minHeight: size.tapHeight)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}
