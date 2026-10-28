import SwiftUI

/// A capsule toggle for the quick filters and the filter sheet. The title arrives localized.
public struct FilterChip: View {
  private let title: String
  private let systemImage: String?
  private let isOn: Bool
  private let action: () -> Void

  public init(title: String, systemImage: String? = nil, isOn: Bool, action: @escaping () -> Void) {
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
      .themeFont(.footnote, weight: .medium)
      .foregroundStyle(isOn ? Theme.Accent.onFill : Theme.Ink.secondary)
      .padding(.horizontal, Theme.Spacing.md)
      .padding(.vertical, Theme.Spacing.sm)
      .background(isOn ? Theme.Accent.fill : Theme.Surface.subtle, in: .capsule)
      .overlay { Capsule().strokeBorder(Theme.Surface.border, lineWidth: isOn ? 0 : 0.5) }
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}
