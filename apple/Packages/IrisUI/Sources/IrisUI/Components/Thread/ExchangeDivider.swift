import SwiftUI

/// The line between two exchanges of a thread (a question with its answer): a hairline with a little air around it, so the
/// turns of one exchange read as a group.
public struct ExchangeDivider: View {
  public init() {}

  public var body: some View {
    Theme.divider
      .frame(height: 1)
      .padding(.top, Theme.Spacing.md)
      .accessibilityHidden(true)
  }
}
