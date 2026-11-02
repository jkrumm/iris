import SwiftUI

/// The line between two exchanges of a thread (a question with its answer): a hairline with a little air around it, so the
/// turns of one exchange read as a group. With a `title` (the day the exchange started) the line breaks around it: the
/// turns carry only the clock time, the date lives here.
public struct ExchangeDivider: View {
  private let title: String?

  public init(title: String? = nil) {
    self.title = title
  }

  public var body: some View {
    HStack(spacing: Theme.Spacing.sm) {
      rule
      if let title {
        Text(verbatim: title)
          .themeFont(.caption, weight: .semibold)
          .foregroundStyle(Theme.Ink.faint)
          .textCase(.uppercase)
        rule
      }
    }
    .padding(.top, Theme.Spacing.md)
    .accessibilityElement(children: .combine)
    .accessibilityHidden(title == nil)
  }

  private var rule: some View {
    Theme.divider.frame(height: 1)
  }
}
