import CoreGraphics
import SwiftUI

/// Iris's answer as a turn of the conversation: a bubble on the panel surface on the left holding the reply as a rendered
/// document, the time under it. A `footer` (the detail's Play reply) sits inside the bubble under the reply; `onCopy` adds Copy to
/// its long press.
public struct AssistantTurnView<Footer: View>: View {
  private let markdown: String
  private let time: String
  private let mermaid: [Int: MermaidAsset]
  private let identifier: String
  private let onOpenImage: (CGImage) -> Void
  private let onCopy: (() -> Void)?
  private let hasFooter: Bool
  private let footer: Footer

  /// - Parameter hasFooter: `false` when the footer builds nothing (an `if` that did not hold): no hairline, no empty row.
  public init(
    markdown: String, time: String, mermaid: [Int: MermaidAsset] = [:], identifier: String = "thread.turn.assistant",
    onOpenImage: @escaping (CGImage) -> Void = { _ in }, onCopy: (() -> Void)? = nil, hasFooter: Bool = true,
    @ViewBuilder footer: () -> Footer
  ) {
    self.markdown = markdown
    self.time = time
    self.mermaid = mermaid
    self.identifier = identifier
    self.onOpenImage = onOpenImage
    self.onCopy = onCopy
    self.hasFooter = hasFooter
    self.footer = footer()
  }

  public var body: some View {
    ChatBubble(side: .assistant, time: time, onCopy: onCopy, hasFooter: hasFooter) {
      MessageContentView(markdown: markdown, mermaid: mermaid, onOpenImage: onOpenImage)
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
    markdown: String, time: String, mermaid: [Int: MermaidAsset] = [:], identifier: String = "thread.turn.assistant",
    onOpenImage: @escaping (CGImage) -> Void = { _ in }, onCopy: (() -> Void)? = nil
  ) {
    self.init(
      markdown: markdown, time: time, mermaid: mermaid, identifier: identifier, onOpenImage: onOpenImage,
      onCopy: onCopy, hasFooter: false, footer: { EmptyView() })
  }
}
