import CoreGraphics
import IrisCore
import IrisUI
import SwiftUI

/// The conversation of the main window's detail as bubbles: what was said on the right, Iris's answers rendered as documents on the
/// left, an answer still on its way as the pending bubble with the pipeline's dashes, a failed turn in the failure colour, and a
/// line between two exchanges. The turns are the iPhone's own component (``ConversationTurnList``) at the desktop's 13 pt. The
/// pane owns the scrolling.
struct MacConversationView: View {
  let turns: [ConversationTurn]
  /// A bubble's Copy: the plain text of the turn.
  let onCopy: (String) -> Void
  /// A tap on a rendered diagram.
  let onOpenImage: (CGImage) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.macTurnGap) {
      ConversationTurnList(
        turns: turns, style: .mac, dayTitle: { HistoryDaySection.title(of: $0) },
        plainText: { PlainMarkdown.text(from: $0) }, onCopy: onCopy, onOpenImage: onOpenImage)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Conversation", comment: "Accessibility label of the detail's conversation"))
    .accessibilityIdentifier("mac.detail.conversation")
  }
}
