import Foundation

/// What to render of the last block of a reply that is still arriving, so nothing half-written flashes: an emphasis that has
/// not closed yet is closed, a link that has no URL yet is its label, a table header waits for its delimiter row, a formula
/// that has not ended is left out. Text inside a fence or a closed code span is never touched; an unclosed fence stays as it
/// is (it renders as code). Complete text comes back unchanged.
enum StreamingTail {
  static func stabilize(_ markdown: String) -> String {
    var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard !endsInOpenFence(lines) else { return markdown }

    var held = false
    while let first = heldBackLine(in: lines) {
      lines.removeSubrange(first...)
      held = true
    }
    var text = held ? lines.joined(separator: "\n") : markdown
    if let start = MathSpans.unclosedSpanStart(in: text) { text = String(text[..<start]) }
    return closingInline(text)
  }

  // MARK: Lines

  private static func endsInOpenFence(_ lines: [String]) -> Bool {
    var fence: MessageBlock.Fence?
    for line in lines {
      if let open = fence {
        if MessageBlock.closes(line, fence: open) { fence = nil }
      } else {
        fence = MessageBlock.opening(line)
      }
    }
    return fence != nil
  }

  /// The first line to drop when the last line with content is a fence opener still being typed (one or two backticks or
  /// tildes), an ATX heading with no text, or a table header whose delimiter row has not arrived. Nil when nothing is held.
  private static func heldBackLine(in lines: [String]) -> Int? {
    guard let last = lines.lastIndex(where: { !$0.allSatisfy(\.isWhitespace) }) else { return nil }
    let line = lines[last].trimmingCharacters(in: .whitespaces)
    if line.count <= 2, line.allSatisfy({ $0 == "`" }) || line.allSatisfy({ $0 == "~" }) { return last }
    if line.count <= 6, line.allSatisfy({ $0 == "#" }) { return last }
    guard !lines[last].hasPrefix("    "), !lines[last].hasPrefix("\t"), hasPipeOutsideCode(line) else { return nil }
    let above = last > 0 ? lines[last - 1].trimmingCharacters(in: .whitespaces) : ""
    if isDelimiterShaped(line) { return hasPipeOutsideCode(above) ? last - 1 : last }
    return isDelimiterShaped(above) && hasPipeOutsideCode(above) ? nil : last
  }

  private static func hasPipeOutsideCode(_ line: String) -> Bool {
    let withoutCode = line.replacingOccurrences(of: "`[^`]*(`|$)", with: "", options: .regularExpression)
    return withoutCode.contains("|")
  }

  /// Only pipes, colons, dashes and spaces, and at least one dash or pipe: a delimiter row, or the start of one.
  private static func isDelimiterShaped(_ line: String) -> Bool {
    !line.isEmpty && line.allSatisfy { "|:- ".contains($0) } && (line.contains("-") || line.contains("|"))
  }

  // MARK: Inline

  /// The text with the inline construct that is still open at its end finished or left out. Only the last paragraph (from the
  /// last line that starts a list item, quote or heading) can hold one.
  private static func closingInline(_ text: String) -> String {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    // One newline at the end is a line break inside the paragraph, not a blank line.
    if lines.count > 1, lines.last == "" { lines.removeLast() }
    var regionStart = 0
    var fence: MessageBlock.Fence?
    for (index, line) in lines.enumerated() {
      if let open = fence {
        if MessageBlock.closes(line, fence: open) {
          fence = nil
          regionStart = index + 1
        }
      } else if line.allSatisfy(\.isWhitespace) {
        regionStart = index + 1
      } else if let opening = MessageBlock.opening(line) {
        fence = opening
      } else if startsBlock(line) {
        regionStart = index
      }
    }
    guard regionStart < lines.count else { return text }
    let head = lines[..<regionStart].map { $0 + "\n" }.joined()
    let region = lines[regionStart...].joined(separator: "\n")
    let closed = head + closing(region)
    return closed == head + region ? text : closed
  }

  private static func startsBlock(_ line: String) -> Bool {
    let trimmed = String(line.drop { $0 == " " || $0 == "\t" })
    return MessageBlock.isListMarker(trimmed) || trimmed.hasPrefix(">") || trimmed.hasPrefix("#")
  }

  private struct Opener {
    var mark: Character
    var length: Int
    var range: Range<Int>
  }

  private static func closing(_ region: String) -> String {
    let c = Array(region)
    var deleted = Set<Int>()
    var end = c.count
    var openers: [Opener] = []
    var codeCloser = ""
    var index = 0

    scan: while index < end {
      switch c[index] {
      case "\\":
        index += 2
      case "`":
        let length = MessageBlock.backtickRun(in: c, at: index)
        if let close = MathSpans.codeSpanClose(in: c, opening: index, length: length), close + length <= end {
          index = close + length
        } else {
          if c[(index + length)..<end].contains(where: { !$0.isWhitespace }) {
            codeCloser = String(repeating: "`", count: length)
          } else {
            end = index
          }
          break scan
        }
      case "!", "[":
        guard let step = link(in: c, at: index, end: end) else {
          index += 1
          continue
        }
        deleted.formUnion(step.deleted)
        end = step.end ?? end
        index = step.next
      case "<":
        let next = index + 1 < end ? c[index + 1] : nil
        if let next, next.isLetter || next == "/" || next == "!", !c[index..<end].contains(">") {
          end = index
        } else {
          index += 1
        }
      case "*", "_", "~":
        let mark = c[index]
        var length = 1
        while index + length < end, c[index + length] == mark { length += 1 }
        defer { index += length }
        if mark == "~", length != 2 { continue }
        delimiter(mark, length: length, at: index, in: c, end: end, openers: &openers, deleted: &deleted)
      default:
        index += 1
      }
    }
    // The cases that advance by a run length do it in a `defer`; the others above set `index` themselves.

    while let top = openers.last, !hasText(in: c, from: top.range.upperBound, to: end, skipping: deleted) {
      deleted.formUnion(top.range)
      openers.removeLast()
    }
    let kept = c[..<end].indices.filter { !deleted.contains($0) }.map { c[$0] }
    var result = String(kept)
    if codeCloser.isEmpty, openers.isEmpty { return result }
    if codeCloser.isEmpty { result = String(result.reversed().drop { $0.isWhitespace }.reversed()) }
    result += codeCloser
    for opener in openers.reversed() { result += String(repeating: opener.mark, count: opener.length) }
    return result
  }

  private static func hasText(in c: [Character], from start: Int, to end: Int, skipping deleted: Set<Int>) -> Bool {
    guard start < end else { return false }
    return (start..<end).contains { !deleted.contains($0) && !c[$0].isWhitespace }
  }

  private static func delimiter(
    _ mark: Character, length: Int, at index: Int, in c: [Character], end: Int, openers: inout [Opener],
    deleted: inout Set<Int>
  ) {
    let before = index > 0 ? c[index - 1] : nil
    let after = index + length < end ? c[index + length] : nil
    var canOpen = after.map { !$0.isWhitespace } ?? false
    var canClose = before.map { !$0.isWhitespace } ?? false
    if mark == "_" {
      canOpen = canOpen && !(before?.isLetter == true || before?.isNumber == true)
      canClose = canClose && !(after?.isLetter == true || after?.isNumber == true)
    }
    var remaining = length
    if canClose {
      while remaining > 0, let match = openers.lastIndex(where: { $0.mark == mark }) {
        openers.removeSubrange((match + 1)...)
        let used = min(remaining, openers[match].length)
        openers[match].length -= used
        remaining -= used
        if openers[match].length == 0 { openers.remove(at: match) }
      }
    }
    guard remaining == length else { return }
    if canOpen {
      openers.append(Opener(mark: mark, length: length, range: index..<index + length))
    } else if !hasText(in: c, from: index + length, to: end, skipping: []) {
      deleted.formUnion(index..<index + length)
    }
  }

  /// A link or image starting at `index` (`[` or `!`): what to delete, where the text ends if it is cut short, and where the
  /// scan goes on. Nil when it is plain brackets or a text that is not one. A complete link is skipped whole.
  private static func link(
    in c: [Character], at index: Int, end: Int
  ) -> (deleted: Set<Int>, end: Int?, next: Int)? {
    let isImage = c[index] == "!"
    let open = isImage ? index + 1 : index
    guard open < end, c[open] == "[" else { return nil }
    guard let close = matching(c, open: open, opening: "[", closing: "]", end: end) else {
      return isImage ? ([], index, index) : ([open], nil, open + 1)
    }
    let label = String(c[(open + 1)..<close])
    guard !(label == " " || label == "x" || label == "X") else { return nil }
    if close + 1 == end {
      return isImage ? ([], index, index) : ([open, close], nil, open + 1)
    }
    guard c[close + 1] == "(" else { return nil }
    guard let paren = matching(c, open: close + 1, opening: "(", closing: ")", end: end) else {
      return isImage ? ([], index, index) : ([open], close, open + 1)
    }
    return ([], nil, paren + 1)
  }

  private static func matching(
    _ c: [Character], open: Int, opening: Character, closing: Character, end: Int
  ) -> Int? {
    var depth = 0
    var index = open
    while index < end {
      if c[index] == "\\" {
        index += 2
        continue
      }
      if c[index] == opening {
        depth += 1
      } else if c[index] == closing {
        depth -= 1
        if depth == 0 { return index }
      }
      index += 1
    }
    return nil
  }
}
