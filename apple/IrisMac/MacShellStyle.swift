import IrisUI
import SwiftUI

/// The Basalt look of the main window's native lists. The platform keeps what it does better than a repaint (selection, arrow keys,
/// focus ring, the sidebar's behaviour); the surface, the row ink and the separators come from ``Theme``.
extension View {
  /// A native `List` on a ``Theme`` surface instead of the system's background, its separators in the hairline token.
  func macShellList(_ surface: Color) -> some View {
    scrollContentBackground(.hidden)
      .background(surface)
      .listRowSeparatorTint(Theme.Surface.hairline)
  }

  /// Text or an icon in a list row: `color` normally, the text-on-accent token while the row is the emphasized selection (explicit
  /// colors do not flip on the selection the way the system's semantic styles do).
  func macRowInk(_ color: Color) -> some View { modifier(MacRowInk(color: color)) }

  /// A Settings pane: a grouped form on the window surface, its grouped sections on the panel surface.
  func macSettingsPane() -> some View {
    formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .background(Theme.Surface.background)
      .foregroundStyle(Theme.Ink.primary)
      .tint(Theme.Accent.fill)
  }

  /// A section of a ``macSettingsPane`` form.
  func macSettingsRow() -> some View { listRowBackground(Theme.Surface.panel) }
}

private struct MacRowInk: ViewModifier {
  let color: Color
  @Environment(\.backgroundProminence) private var prominence

  func body(content: Content) -> some View {
    content.foregroundStyle(prominence == .increased ? Theme.Accent.onFill : color)
  }
}

/// A one-pixel separator in the hairline token (the system `Divider` draws the system's separator color).
struct MacShellDivider: View {
  var body: some View {
    Theme.Surface.hairline.frame(height: 1)
  }
}
