import CoreGraphics
import SwiftUI

/// Iris's answer as a turn of the thread: the speaker line, then the reply as a rendered document.
public struct AssistantTurnView: View {
  private let markdown: String
  private let time: String
  private let mermaid: [Int: MermaidAsset]
  private let onOpenImage: (CGImage) -> Void

  public init(
    markdown: String, time: String, mermaid: [Int: MermaidAsset] = [:],
    onOpenImage: @escaping (CGImage) -> Void = { _ in }
  ) {
    self.markdown = markdown
    self.time = time
    self.mermaid = mermaid
    self.onOpenImage = onOpenImage
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.snug) {
      TurnHeader(speaker: .assistant, time: time)
      MessageContentView(markdown: markdown, mermaid: mermaid, onOpenImage: onOpenImage)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("thread.turn.assistant")
  }
}
