import SwiftUI

/// What the user said (spoken or typed) as a turn of the thread: a quiet card under the speaker line.
public struct UserTurnView: View {
  private let text: String
  private let time: String

  public init(text: String, time: String) {
    self.text = text
    self.time = time
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      TurnHeader(speaker: .user, time: time)
      Text(verbatim: text)
        .themeFont(.subheadline)
        .foregroundStyle(Theme.Ink.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.Surface.subtle, in: .rect(cornerRadius: Theme.Radius.card))
        .overlay {
          RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(Theme.Surface.border, lineWidth: 0.5)
        }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("thread.turn.user")
  }
}
