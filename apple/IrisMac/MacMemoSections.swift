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

  /// The small Copy at the transcript's label: the whole text (every part of a continued transcript), the toolbar's Copy in place.
  private var transcriptCopy: some View {
    let copied = model.copied == .transcript
    return Button {
      model.copy(.transcript)
    } label: {
      Label(
        copied
          ? String(localized: "Copied", comment: "Detail: confirmation after Copy")
          : String(localized: "Copy", comment: "Detail: copies the section as plain text"),
        systemImage: copied ? "checkmark" : "doc.on.doc"
      )
      .macFont(.caption)
      .textCase(nil)
    }
    .buttonStyle(.borderless)
    .foregroundStyle(Theme.Ink.muted)
    .help(MacMemoControl.copyTranscriptSection.help)
    .accessibilityIdentifier("mac.detail.transcript.copy")
  }

  /// The transcript: one block per recording, a blank line between them, so a continued transcript reads as the one text Copy puts on
  /// the pasteboard.
  @ViewBuilder private func transcript(_ memo: Memo) -> some View {
    let parts = model.parts.filter { $0.transcript != nil }
    if !parts.isEmpty {
      MacSection(
        String(localized: "Transcript", comment: "Section label of the transcript"),
        accessory: { transcriptCopy }
      ) {
        VStack(alignment: .leading, spacing: Theme.Spacing.macSectionGap) {
          ForEach(parts) { part in
            Text(verbatim: part.transcript ?? "")
              .macFont(.body)
              .lineSpacing(Theme.Spacing.macLineSpacing)
              .foregroundStyle(Theme.Ink.primary)
              .textSelection(.enabled)
              .accessibilityIdentifier(part.id == memo.id ? "mac.detail.transcript" : "mac.detail.transcript.part")
          }
        }
      }
    }
  }
}

/// A section: its small uppercase label (with an optional control at its trailing end), then the content.
struct MacSection<Accessory: View, Content: View>: View {
  private let title: String
  private let accessory: Accessory
  private let content: Content

  init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
    self.title = title
    self.accessory = accessory()
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.macLabelGap) {
      HStack(spacing: Theme.Spacing.snug) {
        Text(verbatim: title)
          .macFont(.caption, weight: .semibold)
          .textCase(.uppercase)
          .foregroundStyle(Theme.Ink.muted)
          .accessibilityAddTraits(.isHeader)
        accessory
        Spacer(minLength: 0)
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

extension MacSection where Accessory == EmptyView {
  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.init(title, accessory: { EmptyView() }, content: content)
  }
}
