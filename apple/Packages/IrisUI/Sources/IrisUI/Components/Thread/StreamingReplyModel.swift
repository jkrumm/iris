import Foundation

/// The blocks of a reply that grows token by token. The blocks before the last one are kept with the text they came from, so
/// an update splits only what follows them and the views of the kept blocks see the same strings (Textual re-parses a whole
/// string when it changes). While streaming the last text block goes through ``StreamingTail/stabilize(_:)``; a final update
/// (`isStreaming == false`) is exactly `MessageBlock.split(markdown).identified`: one block per text run, so the text ids change
/// at that moment and the views remount.
struct StreamingReplyModel {
  private var committed: [MessageBlock] = []
  private var committedPrefix = ""
  private var committedMermaids = 0
  private var hasReference = false
  private var lastInput: (markdown: String, isStreaming: Bool)?
  private(set) var blocks: [IdentifiedBlock] = []

  @discardableResult
  mutating func update(markdown: String, isStreaming: Bool) -> [IdentifiedBlock] {
    if let lastInput, lastInput.markdown == markdown, lastInput.isStreaming == isStreaming { return blocks }
    lastInput = (markdown, isStreaming)
    guard isStreaming else {
      blocks = MessageBlock.split(markdown).identified
      return blocks
    }
    var tail = rebuild(markdown)
    if case .markdown(let text)? = tail.last {
      let stable = StreamingTail.stabilize(text)
      if stable.allSatisfy(\.isWhitespace) {
        tail.removeLast()
      } else {
        tail[tail.count - 1] = .markdown(stable)
      }
    }
    blocks = (committed + tail).identified
    return blocks
  }

  private mutating func reset() {
    committed = []
    committedPrefix = ""
    committedMermaids = 0
    hasReference = false
  }

  private static func hasReferenceDefinition(_ text: String) -> Bool {
    text.split(separator: "\n", omittingEmptySubsequences: false).contains {
      MessageBlock.isReferenceDefinition(String($0))
    }
  }

  /// Splits what follows the committed prefix (or everything) and commits the blocks that can no longer change; returns the rest.
  private mutating func rebuild(_ markdown: String) -> [MessageBlock] {
    var source = markdown
    if !hasReference, markdown.utf8.starts(with: committedPrefix.utf8) {
      let start = markdown.utf8.index(markdown.utf8.startIndex, offsetBy: committedPrefix.utf8.count)
      source = String(markdown[start...])
    } else {
      reset()
    }
    // A link definition anywhere keeps the whole document unchunked, so nothing is kept between updates.
    if Self.hasReferenceDefinition(source) {
      reset()
      hasReference = true
      return MessageBlock.tracked(markdown, chunked: true, partialTail: true).blocks
    }
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    let split = MessageBlock.tracked(
      source, startingMermaidIndex: committedMermaids, chunked: true, partialTail: true)
    let lastLine = lines.count - 1
    let keep = (1..<max(split.blocks.count, 1)).last { index in
      guard split.startLines[index] < lastLine else { return false }
      if case .table = split.blocks[index] { return split.startLines[index] + 1 < lastLine }
      return true
    }
    guard let keep else { return split.blocks }
    let offset = lines[..<split.startLines[keep]].reduce(0) { $0 + $1.utf8.count + 1 }
    let end = source.utf8.index(source.utf8.startIndex, offsetBy: offset)
    committedPrefix += source[..<end]
    committed += split.blocks[..<keep]
    committedMermaids += split.blocks[..<keep].filter { if case .mermaid = $0 { true } else { false } }.count
    return Array(split.blocks[keep...])
  }
}
