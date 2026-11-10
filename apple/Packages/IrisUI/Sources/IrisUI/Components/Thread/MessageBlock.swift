import Foundation

/// One piece of an assistant reply as the thread view lays it out. Textual renders `markdown`; the other two are
/// what it cannot give a narrow phone: a table that scrolls sideways, and a Mermaid diagram the server rendered.
public enum MessageBlock: Equatable, Sendable {
  case markdown(String)
  case table(MarkdownTable)
  /// The `index`th top-level ```mermaid fence of the reply, counted like the server's `ReplyBlock.index`. `source` is
  /// the fence as written, shown as code when the server rendered no image for it.
  case mermaid(index: Int, source: String)
}

/// A GitHub-flavoured pipe table: a header row and the body rows, each padded or cut to the header's width, and how each
/// column is aligned (the delimiter row's colons).
public struct MarkdownTable: Equatable, Sendable {
  public enum Alignment: Equatable, Sendable {
    case leading, center, trailing
  }

  public var headers: [String]
  public var rows: [[String]]
  /// One per header; a column with no colon in its delimiter cell is `.leading`.
  public var alignments: [Alignment]

  public init(headers: [String], rows: [[String]], alignments: [Alignment] = []) {
    self.headers = headers
    self.rows = rows
    self.alignments = headers.indices.map { alignments.indices.contains($0) ? alignments[$0] : .leading }
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

  struct Fence {
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
      blocks.append(.markdown(MessageBlock.tyingUnits(in: joined)))
    }
  }

  // MARK: Number and unit

  private static let unitPattern: NSRegularExpression? = {
    let units = "ms|sec|secs|s|min|mins|h|hr|hrs|days?|weeks?|KB|MB|GB|TB|kB|KiB|MiB|GiB|B|Hz|kHz|MHz|GHz|px|pt"
    return try? NSRegularExpression(pattern: "(?<=\\d) (?=%|(?:\(units))\\b)")
  }()

  /// Replaces the space between a number and its unit ("2 s", "38 MB", "12 %") with a no-break space, so a line never wraps
  /// between them. Code (fenced or inline) is left as written: its spaces are the author's.
  static func tyingUnits(in markdown: String) -> String {
    guard let pattern = unitPattern else { return markdown }
    var fence: Fence?
    var lines: [String] = []
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      if let open = fence {
        if closes(line, fence: open) { fence = nil }
        lines.append(line)
      } else if let opening = opening(line) {
        fence = opening
        lines.append(line)
      } else {
        lines.append(tyingUnits(inProseLine: line, pattern: pattern))
      }
    }
    return lines.joined(separator: "\n")
  }

  /// One line outside a fence. A code span is an opening run of backticks up to the next run of exactly the same length
  /// (CommonMark): ``` `a` ``` and ``` ``a ` b`` ``` are spans, an opening run with no matching close is literal text.
  private static func tyingUnits(inProseLine line: String, pattern: NSRegularExpression) -> String {
    let characters = Array(line)
    var result = ""
    var prose = ""
    func flush() {
      result += pattern.stringByReplacingMatches(
        in: prose, range: NSRange(prose.startIndex..., in: prose), withTemplate: "\u{00A0}")
      prose = ""
    }
    var index = 0
    while index < characters.count {
      guard characters[index] == "`" else {
        prose.append(characters[index])
        index += 1
        continue
      }
      let length = backtickRun(in: characters, at: index)
      var search = index + length
      var close: Int?
      while search < characters.count {
        if characters[search] == "`" {
          let candidate = backtickRun(in: characters, at: search)
          if candidate == length {
            close = search
            break
          }
          search += candidate
        } else {
          search += 1
        }
      }
      if let close {
        flush()
        result += String(characters[index..<close + length])
        index = close + length
      } else {
        prose += String(repeating: "`", count: length)
        index += length
      }
    }
    flush()
    return result
  }

  static func backtickRun(in characters: [Character], at start: Int) -> Int {
    var end = start
    while end < characters.count, characters[end] == "`" { end += 1 }
    return end - start
  }

  // MARK: Fences

  /// ```` ``` ```` or `~~~` up to three spaces in, then an info string (which cannot hold a backtick after a backtick fence).
  static func opening(_ line: String) -> Fence? {
    guard let (marker, length, info) = fenceParts(line) else { return nil }
    if marker == "`", info.contains("`") { return nil }
    let language = info.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() }
    return Fence(marker: marker, length: length, isMermaid: language == "mermaid", lines: [])
  }

  static func closes(_ line: String, fence: Fence) -> Bool {
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
    return (MarkdownTable(headers: headers, rows: rows, alignments: delimiter.map(alignment(ofDelimiterCell:))), index)
  }

  private static func alignment(ofDelimiterCell cell: String) -> MarkdownTable.Alignment {
    switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
    case (true, true): .center
    case (false, true): .trailing
    default: .leading
    }
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
