import SwiftUI

/// The one primary button: `Theme.Accent.fill` with a white label (`onFill`), a capsule. The system prominent styles take
/// the app's text accent, which is pale in dark mode and pairs with a white or black label depending on the context.
/// Disabled it is a quiet panel with a muted label: readable as "not yet", never a washed-out copy of the live button.
/// `.controlSize(.large)` makes the roomy variant used by sheets.
public struct PrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.controlSize) private var controlSize

  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    let isLarge = controlSize == .large || controlSize == .extraLarge
    configuration.label
      .themeFont(.callout, weight: .semibold)
      .foregroundStyle(isEnabled ? Theme.Accent.onFill : Theme.Ink.muted)
      .padding(.horizontal, isLarge ? Theme.Spacing.lg : Theme.Spacing.md)
      .padding(.vertical, isLarge ? Theme.Spacing.md : Theme.Spacing.sm)
      .background(isEnabled ? Theme.Accent.fill : Theme.Surface.elevated, in: .capsule)
      .overlay {
        if !isEnabled { Capsule().strokeBorder(Theme.Surface.border, lineWidth: 0.5) }
      }
      .opacity(configuration.isPressed ? 0.8 : 1)
      .contentShape(.capsule)
  }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
  /// `Theme.Accent.fill` with a white label; see ``PrimaryButtonStyle``.
  public static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}
