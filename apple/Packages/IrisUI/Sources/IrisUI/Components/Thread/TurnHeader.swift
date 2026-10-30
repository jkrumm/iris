import SwiftUI

/// The line above a turn: a small avatar, who spoke, and when.
struct TurnHeader: View {
  enum Speaker {
    case user
    case assistant
  }

  let speaker: Speaker
  let time: String

  var body: some View {
    HStack(spacing: Theme.Spacing.sm) {
      Image(systemName: speaker == .user ? "person.fill" : "sparkles")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(speaker == .user ? Theme.Ink.secondary : Theme.Accent.onFill)
        .frame(width: 22, height: 22)
        .background(speaker == .user ? Theme.Surface.border : Theme.Accent.fill, in: .circle)
        .accessibilityHidden(true)
      Text(speaker == .user ? "You" : "Iris", bundle: #bundle, comment: "Who spoke a turn in a thread")
        .themeFont(.footnote, weight: .semibold)
        .foregroundStyle(Theme.Ink.muted)
      Spacer(minLength: Theme.Spacing.sm)
      Text(verbatim: time)
        .themeFont(.caption)
        .foregroundStyle(Theme.Ink.faint)
    }
    .accessibilityElement(children: .combine)
  }
}
