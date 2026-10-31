import CoreGraphics
import SwiftUI
import Textual

/// An assistant reply laid out block by block: Textual for text, lists, links, code and quotes, the grid-or-cards table,
/// and the server's Mermaid images. A Mermaid fence the server did not render (no entry in `mermaid`) shows as code.
public struct MessageContentView: View {
  private let blocks: [MessageBlock]
  private let mermaid: [Int: MermaidAsset]
  private let onOpenImage: (CGImage) -> Void

  public init(markdown: String, mermaid: [Int: MermaidAsset] = [:], onOpenImage: @escaping (CGImage) -> Void = { _ in })
  {
    blocks = MessageBlockCache.blocks(for: markdown)
    self.mermaid = mermaid
    self.onOpenImage = onOpenImage
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.cozy) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        view(for: block)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private func view(for block: MessageBlock) -> some View {
    switch block {
    case .markdown(let text):
      markdown(text)
    case .table(let table):
      MarkdownTableView(table: table)
    case .mermaid(let index, let source):
      if let asset = mermaid[index] {
        MermaidImageView(asset: asset, onOpen: onOpenImage)
      } else {
        markdown(source)
      }
    }
  }

  private func markdown(_ text: String) -> some View {
    StructuredText(markdown: text)
      .textual.inlineStyle(.iris)
      .irisMarkdown()
      .textual.textSelection(.enabled)
      .textual.paragraphStyle(IrisParagraphStyle())
      .textual.listItemSpacing(IrisParagraphStyle.listItemSpacing)
      .themeFont(.callout)
      .foregroundStyle(Theme.Ink.primary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}
