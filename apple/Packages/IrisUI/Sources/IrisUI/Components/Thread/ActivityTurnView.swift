import SwiftUI

/// The answer being worked on: a bubble on Iris's side with one row per tool started. Finished rows carry a muted checkmark,
/// the last row is current and pulses. New rows fade in.
public struct ActivityTurnView: View {
  private let lines: [ActivityLine]
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(lines: [ActivityLine]) {
    self.lines = lines
  }

  public var body: some View {
    ChatBubble(side: .assistant, time: "") {
      VStack(alignment: .leading, spacing: Theme.Spacing.snug) {
        ForEach(lines) { line in
          row(line, isCurrent: line.id == lines.last?.id)
            .transition(.opacity)
        }
      }
      .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: lines.count)
    }
    // `.contain`, not `.combine`: each row stays an element of its own (one per tool, for the UI test and VoiceOver's rotor).
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(verbatim: lines.last?.label ?? ""))
    .accessibilityIdentifier("thread.turn.activity")
  }

  private func row(_ line: ActivityLine, isCurrent: Bool) -> some View {
    HStack(spacing: Theme.Spacing.md) {
      if isCurrent {
        Image(systemName: "circle.dotted")
          .foregroundStyle(Theme.Accent.tint)
          .symbolEffect(.pulse, isActive: !reduceMotion)
      } else {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(Theme.Ink.faint)
      }
      Text(verbatim: line.label)
        .foregroundStyle(isCurrent ? Theme.Ink.primary : Theme.Ink.muted)
    }
    .themeFont(.footnote)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("thread.turn.activity.row")
  }
}

/// The quiet line under a streaming reply: a small pulsing dot and the current tool.
struct ActivityFootnote: View {
  let label: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: Theme.Spacing.snug) {
      Image(systemName: "circle.fill")
        .imageScale(.small)
        .symbolEffect(.pulse, isActive: !reduceMotion)
      Text(verbatim: label)
    }
    .themeFont(.caption)
    .foregroundStyle(Theme.Ink.muted)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("thread.turn.activity.line")
  }
}
