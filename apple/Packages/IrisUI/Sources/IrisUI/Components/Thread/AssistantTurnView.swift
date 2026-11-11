import CoreGraphics
import SwiftUI

/// Iris's answer as a turn of the conversation: a bubble on the panel surface on the left holding the reply as a rendered
/// document, the time under it. A `footer` (the detail's Play reply) sits inside the bubble under the reply; `onCopy` adds Copy to
/// its long press.
public struct AssistantTurnView<Footer: View>: View {
  private let markdown: String
  private let time: String
  private let mermaid: [Int: MermaidAsset]
  private let artifacts: [ArtifactAsset.Key: ArtifactAsset]
  private let identifier: String
  private let textRole: Theme.TextRole
  private let onOpenImage: (CGImage) -> Void
  private let onCopy: (() -> Void)?
  private let hasFooter: Bool
  private let isStreaming: Bool
  private let activity: String?
  private let footer: Footer

  /// - Parameters:
  ///   - textRole: The body size of the reply (`MessageContentView`): the iPhone's 16 pt `.callout`, the Mac passes `.footnote`.
  ///   - isStreaming: The markdown grows; the content view buffers and stabilizes it.
  ///   - activity: The current tool's line, a quiet footnote under the text inside the bubble.
  ///   - hasFooter: `false` when the footer builds nothing (an `if` that did not hold): no hairline, no empty row.
  public init(
    markdown: String, time: String, mermaid: [Int: MermaidAsset] = [:],
    artifacts: [ArtifactAsset.Key: ArtifactAsset] = [:], identifier: String = "thread.turn.assistant",
    textRole: Theme.TextRole = .callout, onOpenImage: @escaping (CGImage) -> Void = { _ in },
    onCopy: (() -> Void)? = nil, isStreaming: Bool = false, activity: String? = nil, hasFooter: Bool = true,
    @ViewBuilder footer: () -> Footer
  ) {
    self.markdown = markdown
    self.time = time
    self.mermaid = mermaid
    self.artifacts = artifacts
    self.identifier = identifier
    self.textRole = textRole
    self.onOpenImage = onOpenImage
    self.onCopy = onCopy
    self.isStreaming = isStreaming
    self.activity = activity
    self.hasFooter = hasFooter
    self.footer = footer()
  }

  public var body: some View {
    ChatBubble(side: .assistant, time: time, onCopy: onCopy, hasFooter: hasFooter) {
      VStack(alignment: .leading, spacing: Theme.Spacing.cozy) {
        MessageContentView(
          markdown: markdown, isStreaming: isStreaming, mermaid: mermaid, artifacts: artifacts, textRole: textRole,
          onOpenImage: onOpenImage)
        if let activity { ActivityFootnote(label: activity) }
      }
    } footer: {
      footer
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Iris", bundle: #bundle, comment: "Who spoke a turn in a thread"))
    .accessibilityIdentifier(identifier)
  }
}

extension AssistantTurnView where Footer == EmptyView {
  public init(
    markdown: String, time: String, mermaid: [Int: MermaidAsset] = [:],
    artifacts: [ArtifactAsset.Key: ArtifactAsset] = [:], identifier: String = "thread.turn.assistant",
    textRole: Theme.TextRole = .callout, onOpenImage: @escaping (CGImage) -> Void = { _ in },
    onCopy: (() -> Void)? = nil, isStreaming: Bool = false, activity: String? = nil
  ) {
    self.init(
      markdown: markdown, time: time, mermaid: mermaid, artifacts: artifacts, identifier: identifier,
      textRole: textRole,
      onOpenImage: onOpenImage, onCopy: onCopy, isStreaming: isStreaming, activity: activity, hasFooter: false,
      footer: { EmptyView() })
  }
}
