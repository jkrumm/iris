import CoreGraphics
import SwiftUI
import Textual

/// An assistant reply laid out block by block: Textual for text, lists, links, code and quotes, the sideways-scrolling table,
/// and the server's Mermaid images. A Mermaid fence the server did not render (no entry in `mermaid`) shows as code.
public struct MessageContentView: View {
  private let blocks: [MessageBlock]
  private let mermaid: [Int: MermaidAsset]
  private let onOpenImage: (CGImage) -> Void
  private let textRole: Theme.TextRole

  /// `textRole` is the body size of the text blocks (headings, code and lists scale from it): the iPhone's 16 pt `.callout`, the
  /// Mac passes `.footnote` (13 pt).
  public init(
    markdown: String, mermaid: [Int: MermaidAsset] = [:], textRole: Theme.TextRole = .callout,
    onOpenImage: @escaping (CGImage) -> Void = { _ in }
  ) {
    blocks = MessageBlockCache.blocks(for: markdown)
    self.mermaid = mermaid
    self.textRole = textRole
    self.onOpenImage = onOpenImage
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.cozy) {
      ForEach(blocks.identified) { item in
        view(for: item.block)
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
    let math = MathSpans.prepare(text)
    return StructuredText(markdown: math ?? text, syntaxExtensions: math == nil ? [] : [.math])
      .textual.inlineStyle(.iris)
      .irisMarkdown()
      .textual.textSelection(.enabled)
      .textual.paragraphStyle(IrisParagraphStyle())
      .textual.listItemSpacing(IrisParagraphStyle.listItemSpacing)
      .themeFont(textRole)
      .foregroundStyle(Theme.Ink.primary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A block with an identity that survives the reply changing around it, so a loaded diagram is not handed to another block when
/// one is inserted above it: a Mermaid block is its fence index (the server's `ReplyBlock.index`), text and tables are numbered
/// among their own kind.
struct IdentifiedBlock: Identifiable, Equatable {
  let id: String
  let block: MessageBlock
}

extension [MessageBlock] {
  var identified: [IdentifiedBlock] {
    var texts = 0
    var tables = 0
    return map { block in
      switch block {
      case .markdown:
        defer { texts += 1 }
        return IdentifiedBlock(id: "text-\(texts)", block: block)
      case .table:
        defer { tables += 1 }
        return IdentifiedBlock(id: "table-\(tables)", block: block)
      case .mermaid(let index, _):
        return IdentifiedBlock(id: "mermaid-\(index)", block: block)
      }
    }
  }
}
