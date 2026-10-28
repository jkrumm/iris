import Foundation

/// One piece of an assistant reply as the thread view lays it out. Textual renders `markdown`; the other two are
/// what it cannot give a narrow phone: a table that turns into cards, and a Mermaid diagram the server rendered.
public enum MessageBlock: Equatable, Sendable {
  case markdown(String)
  case table(MarkdownTable)
  /// The `index`th top-level ```mermaid fence of the reply, counted like the server's `ReplyBlock.index`. `source` is
  /// the fence as written, shown as code when the server rendered no image for it.
  case mermaid(index: Int, source: String)
}

/// A GitHub-flavoured pipe table: a header row and the body rows, each padded or cut to the header's width.
public struct MarkdownTable: Equatable, Sendable {
  public var headers: [String]
  public var rows: [[String]]

  public init(headers: [String], rows: [[String]]) {
    self.headers = headers
    self.rows = rows
  }
}

extension MessageBlock {
  /// Splits a reply's markdown into blocks in document order. Fences follow the server's reading (CommonMark: closes on the
  /// same character, at least as long, nothing after it; an unclosed fence runs to the end), so a Mermaid fence gets the
  /// same index as the server's `ReplyBlock.index` and text inside another fence stays that fence's text.
  public static func split(_ markdown: String) -> [MessageBlock] {
    var splitter = Splitter()
    return splitter.run(markdown)
  }

  private struct Fence {
    var marker: Character
    var length: Int
    var isMermaid: Bool
    var lines: [String]
  }

  private struct Splitter {
    var blocks: [MessageBlock] = []
    var text: [String] = []
    var open: Fence?
    var mermaidCount = 0

    mutating func run(_ markdown: String) -> [MessageBlock] {
      let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
      var index = 0
      while index < lines.count {
        let line = lines[index]
        if var fence = open {
          if MessageBlock.closes(line, fence: fence) {
            finish(fence, closing: line)
          } else {
            fence.lines.append(line)
            open = fence
          }
          index += 1
        } else if let fence = MessageBlock.opening(line) {
          open = fence
          open?.lines = [line]
          index += 1
        } else if index + 1 < lines.count, let table = MessageBlock.table(at: index, in: lines) {
          flushText()
          blocks.append(.table(table.table))
          index = table.next
        } else {
          text.append(line)
          index += 1
        }
      }
      if let fence = open { finish(fence, closing: nil) }
      flushText()
      return blocks
    }

    private mutating func finish(_ fence: Fence, closing: String?) {
      open = nil
      let source = (fence.lines + [closing].compactMap { $0 }).joined(separator: "\n")
      guard fence.isMermaid else {
        text.append(source)
        return
      }
      flushText()
      blocks.append(.mermaid(index: mermaidCount, source: source))
      mermaidCount += 1
    }

    private mutating func flushText() {
      let joined = text.joined(separator: "\n")
      text = []
      guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      blocks.append(.markdown(joined))
    }
  }

  // MARK: Fences

  /// ```` ``` ```` or `~~~` up to three spaces in, then an info string (which cannot hold a backtick after a backtick fence).
  private static func opening(_ line: String) -> Fence? {
    guard let (marker, length, info) = fenceParts(line) else { return nil }
    if marker == "`", info.contains("`") { return nil }
    let language = info.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() }
    return Fence(marker: marker, length: length, isMermaid: language == "mermaid", lines: [])
  }

  private static func closes(_ line: String, fence: Fence) -> Bool {
    guard let (marker, length, info) = fenceParts(line) else { return false }
    return marker == fence.marker && length >= fence.length && info.isEmpty
  }

  private static func fenceParts(_ line: String) -> (Character, Int, String)? {
    let indent = line.prefix { $0 == " " }.count
    guard indent <= 3 else { return nil }
    let rest = line.dropFirst(indent)
    guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
    let length = rest.prefix { $0 == marker }.count
    guard length >= 3 else { return nil }
    let info = rest.dropFirst(length).trimmingCharacters(in: .whitespaces)
    return (marker, length, info)
  }

  // MARK: Tables

  /// A table starting at `start`: a header line, a delimiter line of the same width, then rows until a blank line or a
  /// line without a pipe. Indented tables (inside a list) are left to Textual.
  private static func table(at start: Int, in lines: [String]) -> (table: MarkdownTable, next: Int)? {
    let header = lines[start]
    guard header.contains("|"), !header.hasPrefix("    "), !header.hasPrefix("\t") else { return nil }
    let headers = cells(of: header)
    let delimiter = cells(of: lines[start + 1])
    guard headers.count > 1 || header.trimmingCharacters(in: .whitespaces).hasPrefix("|"),
      !delimiter.isEmpty, delimiter.count == headers.count, delimiter.allSatisfy(isDelimiterCell)
    else { return nil }
    var rows: [[String]] = []
    var index = start + 2
    while index < lines.count, lines[index].contains("|"),
      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty
    {
      var row = cells(of: lines[index])
      if row.count < headers.count { row += Array(repeating: "", count: headers.count - row.count) }
      rows.append(Array(row.prefix(headers.count)))
      index += 1
    }
    return (MarkdownTable(headers: headers, rows: rows), index)
  }

  private static func isDelimiterCell(_ cell: String) -> Bool {
    let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    return !core.isEmpty && core.allSatisfy { $0 == "-" }
  }

  /// The cells of a pipe row: outer pipes dropped, `\|` kept as a literal pipe, cells trimmed.
  private static func cells(of line: String) -> [String] {
    var cells: [String] = []
    var current = ""
    var escaped = false
    for character in line.trimmingCharacters(in: .whitespaces) {
      if escaped {
        current.append(character == "|" ? "|" : "\\\(character)")
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "|" {
        cells.append(current)
        current = ""
      } else {
        current.append(character)
      }
    }
    if escaped { current.append("\\") }
    cells.append(current)
    var trimmed = cells.map { $0.trimmingCharacters(in: .whitespaces) }
    if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") { trimmed.removeFirst() }
    if line.trimmingCharacters(in: .whitespaces).hasSuffix("|"), !line.hasSuffix("\\|"), !trimmed.isEmpty {
      trimmed.removeLast()
    }
    return trimmed
  }
}
