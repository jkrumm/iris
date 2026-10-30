import SwiftUI

/// A capsule toggle for the quick filters and the filter sheet. The title arrives localized.
public struct FilterChip: View {
  private let title: String
  private let systemImage: String?
  private let isOn: Bool
  private let size: Size
  private let action: () -> Void

  /// `compact` is the quick-filter row (30 pt, footnote), `regular` the filter sheet's (36 pt, subheadline).
  public enum Size {
    case compact, regular

    fileprivate var height: CGFloat { self == .compact ? Theme.Spacing.chipHeight : Theme.Spacing.chipHeightLarge }
    fileprivate var font: Theme.TextRole { self == .compact ? .footnote : .subheadline }
  }

  public init(
    title: String, systemImage: String? = nil, isOn: Bool, size: Size = .compact, action: @escaping () -> Void
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
      .frame(minHeight: size.height)
      .background(isOn ? Theme.Accent.fill : Theme.Surface.subtle, in: .capsule)
      .overlay { Capsule().strokeBorder(Theme.Surface.border, lineWidth: isOn ? 0 : 0.5) }
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}
