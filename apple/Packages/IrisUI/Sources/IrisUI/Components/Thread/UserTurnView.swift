import SwiftUI

/// What the user said (spoken or typed) as a turn of the thread: a card in the accent tint under the speaker line.
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
        .foregroundStyle(Theme.Ink.primary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.Accent.tint.opacity(0.1), in: .rect(cornerRadius: Theme.Radius.card))
        .overlay {
          RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(Theme.Accent.tint.opacity(0.25), lineWidth: 0.5)
        }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("thread.turn.user")
  }
}
