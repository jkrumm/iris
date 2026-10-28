import SwiftUI
import Textual

extension InlineStyle {
  /// Textual's default inline style with the link in Iris's accent.
  static var iris: InlineStyle {
    InlineStyle()
      .code(.monospaced, .fontScale(0.94))
      .strong(.fontWeight(.semibold))
      .link(.foregroundColor(Theme.Accent.tint))
  }
}
