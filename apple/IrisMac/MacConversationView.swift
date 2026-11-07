import CoreGraphics
import IrisCore
import IrisUI
import SwiftUI

/// The conversation of the main window's detail as bubbles: what was said on the right, Iris's answers rendered as documents on the
/// left (the iPhone's `UserTurnView` / `AssistantTurnView`, text at the desktop's 13 pt), an answer still on its way as the pending
/// bubble with the pipeline's dashes, a failed turn in the failure colour, and a line between two exchanges. The pane owns the
/// scrolling.
struct MacConversationView: View {
  let turns: [ThreadTurn]
  /// A bubble's Copy: the plain text of the turn.
  let onCopy: (String) -> Void
  /// A tap on a rendered diagram.
  let onOpenImage: (CGImage) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.macTurnGap) {
      ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
        VStack(alignment: .leading, spacing: Theme.Spacing.macTurnGap) {
          // A question after an answer opens a new exchange.
          if index > 0, case .user = turn.content { ExchangeDivider(title: day(turn.date)) }
          view(for: turn)
        }
        .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Conversation", comment: "Accessibility label of the detail's conversation"))
    .accessibilityIdentifier("mac.detail.conversation")
  }

  @ViewBuilder private func view(for turn: ThreadTurn) -> some View {
    switch turn.content {
    case .user(let text):
      UserTurnView(
        text: text, time: time(turn.date), identifier: "mac.detail.turn.user", textRole: .footnote,
        onCopy: { onCopy(text) })
    case .assistant(let markdown, let mermaid):
      AssistantTurnView(
        markdown: markdown, time: time(turn.date), mermaid: mermaid, identifier: "mac.detail.turn.assistant",
        textRole: .footnote, onOpenImage: onOpenImage, onCopy: { onCopy(PlainMarkdown.text(from: markdown)) })
    case .pending(let progress, let caption):
      PendingTurnView(progress: progress, caption: caption)
    case .failed(let message):
      Text(verbatim: message)
        .macFont(.body)
        .foregroundStyle(Theme.Status.bad)
        .textSelection(.enabled)
        .accessibilityIdentifier("mac.detail.turn.failed")
    }
  }

  /// The clock time only: the day sits in the exchange dividers.
  private func time(_ date: Date?) -> String {
    date?.formatted(date: .omitted, time: .shortened) ?? ""
  }

  private func day(_ date: Date?) -> String? {
    date.map { HistoryDaySection.title(of: $0) }
  }
}
