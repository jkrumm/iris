import CoreGraphics
import SwiftUI
import Textual

/// An assistant reply laid out block by block: Textual for text, lists, links, code and quotes, the sideways-scrolling table,
/// and the server's Mermaid images. A Mermaid fence the server did not render (no entry in `mermaid`) shows as code.
///
/// `markdown` may grow (`isStreaming`): the text is published through a ``StreamBuffer`` (80 ms, or a new line after 16 ms),
/// only the last chunk is parsed again and its unfinished markup is stabilized. When `isStreaming` is false the view shows
/// `markdown` as it is, at once.
public struct MessageContentView: View {
  private let markdown: String
  private let isStreaming: Bool
  private let isBuffered: Bool
  private let prepared: [IdentifiedBlock]?
  private let mermaid: [Int: MermaidAsset]
  private let onOpenImage: (CGImage) -> Void
  private let textRole: Theme.TextRole
  @State private var session = StreamSession()

  /// `textRole` is the body size of the text blocks (headings, code and lists scale from it): the iPhone's 16 pt `.callout`, the
  /// Mac passes `.footnote` (13 pt).
  public init(
    markdown: String, isStreaming: Bool = false, mermaid: [Int: MermaidAsset] = [:],
    textRole: Theme.TextRole = .callout, onOpenImage: @escaping (CGImage) -> Void = { _ in }
  ) {
    self.init(
      markdown: markdown, isStreaming: isStreaming, isBuffered: true, prepared: nil, mermaid: mermaid,
      textRole: textRole,
      onOpenImage: onOpenImage)
  }

  /// `isBuffered: false` renders every update at once (the caller paces them); `prepared` renders the given blocks as they
  /// are, bypassing the split (the layout of a reply before chunking, for comparison).
  init(
    markdown: String, isStreaming: Bool, isBuffered: Bool, prepared: [IdentifiedBlock]?,
    mermaid: [Int: MermaidAsset] = [:], textRole: Theme.TextRole = .callout,
    onOpenImage: @escaping (CGImage) -> Void = { _ in }
  ) {
    self.markdown = markdown
    self.isStreaming = isStreaming
    self.isBuffered = isBuffered
    self.prepared = prepared
    self.mermaid = mermaid
    self.textRole = textRole
    self.onOpenImage = onOpenImage
  }

  public var body: some View {
    let blocks = currentBlocks
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(blocks.enumerated()), id: \.element.id) { position, item in
        view(for: item.block)
          .modifier(BlockLead(gap: gap(at: position, in: blocks), role: textRole))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onChange(of: markdown) {
      if isStreaming, isBuffered { session.offer(markdown) }
    }
    .onChange(of: isStreaming) {
      session.restart()
    }
    .onDisappear { session.cancel() }
  }

  private var currentBlocks: [IdentifiedBlock] {
    if let prepared { return prepared }
    guard isStreaming else { return MessageBlockCache.blocks(for: markdown).identified }
    return session.blocks(for: isBuffered ? nil : markdown, fallback: markdown)
  }

  /// Only a streaming reply has two text blocks in a row (chunks); a finished one is `cozy` between blocks as before. A text chunk that follows another one sits where the paragraph or heading above it would have put it inside one
  /// Textual view; every other block is `cozy` below the one before.
  private func gap(at position: Int, in blocks: [IdentifiedBlock]) -> BlockLead.Gap {
    guard position > 0 else { return .none }
    guard case .markdown(let text) = blocks[position].block, case .markdown = blocks[position - 1].block else {
      return .cozy
    }
    return .text(em: Self.spaceAbove(firstLineOf: text))
  }

  private static func spaceAbove(firstLineOf text: String) -> CGFloat {
    let line = text.drop { $0 == "\n" || $0 == " " }.prefix { $0 != "\n" }
    let hashes = line.prefix { $0 == "#" }.count
    guard (1...6).contains(hashes), line.dropFirst(hashes).first.map({ $0 == " " || $0 == "\t" }) ?? true else {
      return IrisParagraphStyle.spaceAbove
    }
    return IrisHeadingStyle.spaceAbove(level: hashes)
  }

  @ViewBuilder private func view(for block: MessageBlock) -> some View {
    switch block {
    case .markdown(let text):
      MarkdownBlockView(text: text, textRole: textRole)
    case .table(let table):
      MarkdownTableView(table: table)
    case .mermaid(let index, let source):
      if let asset = mermaid[index] {
        MermaidImageView(asset: asset, onOpen: onOpenImage)
      } else {
        MarkdownBlockView(text: source, textRole: textRole)
      }
    }
  }
}

/// The space above a block: none for the first, `cozy` after a table or diagram, and after another text chunk what Textual
/// puts above the chunk's first block in one view (a paragraph or heading, in ems of the body font).
private struct BlockLead: ViewModifier {
  enum Gap {
    case none, cozy
    case text(em: CGFloat)
  }

  let gap: Gap
  @ScaledMetric private var size: CGFloat

  init(gap: Gap, role: Theme.TextRole) {
    self.gap = gap
    _size = ScaledMetric(wrappedValue: role.baseSize, relativeTo: role.textStyle)
  }

  func body(content: Content) -> some View {
    switch gap {
    case .none: content
    case .cozy: content.padding(.top, Theme.Spacing.cozy)
    case .text(let em): content.padding(.top, em * size)
    }
  }
}

/// One Textual view: a chunk of a reply.
struct MarkdownBlockView: View {
  let text: String
  let textRole: Theme.TextRole

  var body: some View {
    let math = MathSpans.prepare(text)
    StructuredText(markdown: math ?? text, syntaxExtensions: math == nil ? [] : [.math])
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

/// The streaming state of one view: what is published so far, when the next publish is due, and the incremental blocks. Only
/// a streaming view touches it. `shown` is the one observed value; the rest is bookkeeping read in `body` and the handlers.
@MainActor @Observable
private final class StreamSession {
  private(set) var shown: String?
  @ObservationIgnored private var buffer = StreamBuffer()
  @ObservationIgnored private var model = StreamingReplyModel()
  @ObservationIgnored private var pending: Task<Void, Never>?
  @ObservationIgnored private var latest = ""
  @ObservationIgnored private let clock = ContinuousClock()
  @ObservationIgnored private let origin = ContinuousClock.now

  private var now: Duration { origin.duration(to: clock.now) }

  /// `live` is the markdown to show right away (an unbuffered view); nil shows what was published, `fallback` before the
  /// first publish.
  func blocks(for live: String?, fallback: String) -> [IdentifiedBlock] {
    model.update(markdown: live ?? shown ?? fallback, isStreaming: true)
  }

  func offer(_ markdown: String) {
    latest = markdown
    switch buffer.offer(markdown, at: now) {
    case .publish(let text):
      pending?.cancel()
      pending = nil
      shown = text
    case .wait(let deadline):
      guard pending == nil else { return }
      let delay = deadline - now
      pending = Task { [weak self] in
        do { try await Task.sleep(for: delay) } catch { return }
        self?.flush()
      }
    }
  }

  private func flush() {
    pending = nil
    if case .publish(let text) = buffer.publish(latest, at: now) { shown = text }
  }

  func cancel() {
    pending?.cancel()
    pending = nil
  }

  /// Streaming started or stopped: forget what was published and kept.
  func restart() {
    cancel()
    shown = nil
    buffer = StreamBuffer()
    model = StreamingReplyModel()
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
