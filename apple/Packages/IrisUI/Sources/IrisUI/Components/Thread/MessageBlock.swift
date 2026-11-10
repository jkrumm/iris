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
  /// A text run is one `.markdown` block (a finished reply keeps text selection across paragraphs); only a streaming reply is
  /// cut into chunks, see ``tracked(_:startingMermaidIndex:chunked:partialTail:)``.
  public static func split(_ markdown: String) -> [MessageBlock] {
    tracked(markdown).blocks
  }

  /// `split` for the rest of a reply whose first `startingMermaidIndex` diagrams are already behind it.
  static func split(_ markdown: String, startingMermaidIndex: Int) -> [MessageBlock] {
    tracked(markdown, startingMermaidIndex: startingMermaidIndex).blocks
  }

  /// The blocks and the line each one starts on. `chunked: false` keeps a text run as one block (the layout of a reply before
  /// chunking; what the height tests and the benchmark compare against). A document with a link reference definition is
  /// never chunked: a definition can sit below the link that uses it.
  ///
  /// `partialTail` says the last line may still be growing (a stream): it never starts a chunk, since a few more characters can
  /// turn a paragraph into a list item.
  static func tracked(
    _ markdown: String, startingMermaidIndex: Int = 0, chunked: Bool = false, partialTail: Bool = false
  ) -> Split {
    var splitter = Splitter()
    splitter.mermaidCount = startingMermaidIndex
    splitter.partialTail = partialTail
    return splitter.run(markdown, chunked: chunked)
  }

  struct Split {
    var blocks: [MessageBlock] = []
    /// `startLines[i]` is the 0-based line of `blocks[i]`'s first line (a chunk after a cut starts on its first non-blank line).
    var startLines: [Int] = []
  }

  struct Fence {
    var marker: Character
    var length: Int
    var isMermaid: Bool
    var lines: [String]
  }

  private struct Splitter {
    var result = Split()
    var text: [String] = []
    var textStart = 0
    var open: Fence?
    var openStart = 0
    var mermaidCount = 0
    var chunked = true
    var partialTail = false
    var lineCount = 0

    mutating func run(_ markdown: String, chunked: Bool) -> Split {
      let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
      self.chunked = chunked && !lines.contains(where: MessageBlock.isReferenceDefinition)
      lineCount = lines.count
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
          openStart = index
          index += 1
        } else if index + 1 < lines.count, let table = MessageBlock.table(at: index, in: lines) {
          flushText()
          result.blocks.append(.table(table.table))
          result.startLines.append(index)
          index = table.next
        } else {
          if text.isEmpty { textStart = index }
          text.append(line)
          index += 1
        }
      }
      if let fence = open { finish(fence, closing: nil) }
      flushText()
      return result
    }

    private mutating func finish(_ fence: Fence, closing: String?) {
      open = nil
      let source = (fence.lines + [closing].compactMap { $0 }).joined(separator: "\n")
      guard fence.isMermaid else {
        if text.isEmpty { textStart = openStart }
        text.append(source)
        return
      }
      flushText()
      result.blocks.append(.mermaid(index: mermaidCount, source: source))
      result.startLines.append(openStart)
      mermaidCount += 1
    }

    private mutating func flushText() {
      let joined = text.joined(separator: "\n")
      text = []
      guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
      let lines = MessageBlock.tyingUnits(in: joined).split(separator: "\n", omittingEmptySubsequences: false)
      var starts = [0]
      if chunked {
        let cuts = MessageBlock.chunkStarts(in: lines.map(String.init))
        starts += cuts.filter { !(partialTail && textStart + $0 == lineCount - 1) }
      }
      for (position, start) in starts.enumerated() {
        var end = position + 1 < starts.count ? starts[position + 1] : lines.count
        if position + 1 < starts.count {
          while end > start + 1, lines[end - 1].allSatisfy(\.isWhitespace) { end -= 1 }
        }
        result.blocks.append(.markdown(lines[start..<end].joined(separator: "\n")))
        result.startLines.append(textStart + start)
      }
    }
  }

  // MARK: Chunks

  /// The lines (after the first) where a text run is cut into a new block. A cut sits on a blank line outside a fence, a `$$`
  /// span, a rule (Textual puts 1.6 em under it, more than a chunk gap) and a list or quote context, and the line after it
  /// starts a plain paragraph or an ATX heading at column 0. A list marker never starts a chunk (an ordered list restarts its
  /// numbering in a new block), nor does anything else a block above could continue: a quote, a table row, HTML, a link
  /// definition, an indented line, a rule, a fence.
  static func chunkStarts(in lines: [String]) -> [Int] {
    var starts: [Int] = []
    var fence: Fence?
    var inDisplayMath = false
    var previous: String?
    var sawBlank = false
    for (index, line) in lines.enumerated() {
      if let open = fence {
        if closes(line, fence: open) {
          fence = nil
          previous = line
        }
        continue
      }
      if line.allSatisfy(\.isWhitespace) {
        sawBlank = true
        continue
      }
      if sawBlank, !inDisplayMath, let previous, !isIndented(previous), !isThematicBreak(previous), startsChunk(line) {
        starts.append(index)
      }
      sawBlank = false
      previous = line
      if line.components(separatedBy: "$$").count % 2 == 0 { inDisplayMath.toggle() }
      if let opened = opening(line) { fence = opened }
    }
    return starts
  }

  private static func isIndented(_ line: String) -> Bool {
    line.first == " " || line.first == "\t"
  }

  private static func startsChunk(_ line: String) -> Bool {
    guard let first = line.first, first != " ", first != "\t" else { return false }
    if ">|<[".contains(first) || opening(line) != nil { return false }
    if isListMarker(line) || isThematicBreak(line) { return false }
    return true
  }

  /// `-`, `*`, `+` or digits with `.` / `)`, then a space, a tab or the end of the line.
  static func isListMarker(_ line: String) -> Bool {
    var rest = Substring(line)
    if let first = rest.first, "-*+".contains(first) {
      rest = rest.dropFirst()
    } else {
      let digits = rest.prefix { $0.isASCII && $0.isNumber }
      guard !digits.isEmpty else { return false }
      rest = rest.dropFirst(digits.count)
      guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return false }
      rest = rest.dropFirst()
    }
    return rest.first.map { $0 == " " || $0 == "\t" } ?? true
  }

  /// Three or more of the same `-`, `*` or `_`, with spaces allowed between.
  private static func isThematicBreak(_ line: String) -> Bool {
    let marks = line.filter { $0 != " " && $0 != "\t" }
    guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
    return marks.allSatisfy { $0 == first }
  }

  /// `[label]:` up to three spaces in (also a footnote definition).
  static func isReferenceDefinition(_ line: String) -> Bool {
    let rest = line.drop { $0 == " " }
    guard line.count - rest.count <= 3, rest.first == "[", let close = rest.firstIndex(of: "]") else { return false }
    guard rest.index(after: rest.startIndex) < close else { return false }
    let after = rest.index(after: close)
    return after < rest.endIndex && rest[after] == ":"
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
