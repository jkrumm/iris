import IrisCore
import IrisUI
import SwiftUI

/// The document layout under the detail's header, for a memo with no Hermes session (a transcript, one that failed before `act`):
/// sections without boxes, a small uppercase label, the content, spacing between. Details (steps, copy rows, ids) are the toolbar's
/// popover. A memo in a session is a chat instead (``MacConversationView``).
struct MacMemoSections: View {
  let model: MacMemoDetailModel

  var body: some View {
    if let memo = model.memo {
      VStack(alignment: .leading, spacing: Theme.Spacing.macSectionGap) {
        reply(memo)
        summary(memo)
        transcript(memo)
      }
    }
  }

  // MARK: Reply, summary, transcript

  @ViewBuilder private func reply(_ memo: Memo) -> some View {
    if let text = memo.replyText, !text.isEmpty {
      MacSection(String(localized: "Reply", comment: "Section label of the reply")) {
        MessageContentView(markdown: text, artifacts: memo.artifactAssets, textRole: .footnote)
          .accessibilityIdentifier("mac.detail.reply")
      }
    }
  }

  @ViewBuilder private func summary(_ memo: Memo) -> some View {
    if let detail = memo.summary?.detail, !detail.isEmpty {
      MacSection(String(localized: "Summary", comment: "Section label of the summary")) {
        Text(verbatim: detail)
          .macFont(.body)
          .lineSpacing(Theme.Spacing.macLineSpacing)
          .foregroundStyle(Theme.Ink.secondary)
          .textSelection(.enabled)
          .accessibilityIdentifier("mac.detail.summary")
      }
    }
  }

  @ViewBuilder private func transcript(_ memo: Memo) -> some View {
    if let text = memo.transcript {
      MacSection(String(localized: "Transcript", comment: "Section label of the transcript")) {
        Text(verbatim: text)
          .macFont(.body)
          .lineSpacing(Theme.Spacing.macLineSpacing)
          .foregroundStyle(Theme.Ink.primary)
          .textSelection(.enabled)
          .accessibilityIdentifier("mac.detail.transcript")
      }
    }
  }
}

/// A section: its small uppercase label, then the content.
struct MacSection<Content: View>: View {
  private let title: String
  private let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.macLabelGap) {
      Text(verbatim: title)
        .macFont(.caption, weight: .semibold)
        .textCase(.uppercase)
        .foregroundStyle(Theme.Ink.muted)
        .accessibilityAddTraits(.isHeader)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
