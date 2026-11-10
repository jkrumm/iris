import Foundation

/// The LaTeX in a reply's markdown, found by pandoc's rules instead of Textual's regexes, which pair any two dollar signs
/// ("$5 and $10" would become a formula). `prepare(_:)` rewrites a block so Textual's `.math` extension sees exactly the
/// spans found here.
enum MathSpans {
  enum Token: Equatable {
    /// Prose, newlines included.
    case text(String)
    /// A fenced block or a code span, as written.
    case code(String)
    case math(latex: String, isBlock: Bool)
  }

  /// A small dollar sign (U+FE69): looks like `$`, but is not one to Textual's regexes.
  private static let strayDollar: Character = "\u{FE69}"

  /// The markdown with every valid span protected from Foundation's markdown parser and every other dollar sign defused,
  /// or nil when the block has no valid span (then `.math` stays off and the text is rendered as written).
  static func prepare(_ markdown: String) -> String? {
    guard markdown.contains("$") else { return nil }
    let tokens = tokens(in: markdown)
    guard tokens.contains(where: { if case .math = $0 { true } else { false } }) else { return nil }
    return tokens.map { token in
      switch token {
      case .text(let text): defuse(text)
      case .code(let code): code
      case .math(let latex, let isBlock):
        isBlock ? "$$\(protect(latex))$$" : "$\(protect(latex))$"
      }
    }.joined()
  }

  static func tokens(in markdown: String) -> [Token] {
    var tokens: [Token] = []
    var prose = ""
    var code = ""
    var fence: MessageBlock.Fence?
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
    for (index, line) in lines.enumerated() {
      let line = String(line)
      let terminated = index < lines.count - 1 ? line + "\n" : line
      if let open = fence {
        code += terminated
        guard MessageBlock.closes(line, fence: open) else { continue }
        fence = nil
        tokens.append(.code(code))
        code = ""
      } else if let opening = MessageBlock.opening(line) {
        tokens += scan(prose)
        prose = ""
        fence = opening
        code = terminated
      } else {
        prose += terminated
      }
    }
    tokens += scan(prose)
    if !code.isEmpty { tokens.append(.code(code)) }
    return tokens
  }

  /// Where a `$$` or `$` span that is still being typed starts: an opening delimiter the reply has not closed yet. A single
  /// dollar counts only on the last line (it cannot span lines) and not when it reads as a price ("$12.50").
  static func unclosedSpanStart(in markdown: String) -> String.Index? {
    guard markdown.contains("$"), case .text(let tail)? = tokens(in: markdown).last else { return nil }
    let c = Array(tail)
    let base = markdown.index(markdown.endIndex, offsetBy: -c.count)
    func position(_ offset: Int) -> String.Index { markdown.index(base, offsetBy: offset) }
    var index = 0
    while index < c.count {
      if c[index] == "\\" {
        index += 2
      } else if c[index] == "$", index + 1 < c.count, c[index + 1] == "$" {
        return position(index)
      } else {
        index += 1
      }
    }
    var last: Int?
    var scan = c.lastIndex(of: "\n").map { $0 + 1 } ?? 0
    while scan < c.count {
      if c[scan] == "\\" {
        scan += 2
        continue
      }
      if c[scan] == "$" { last = scan }
      scan += 1
    }
    guard let last, last + 1 < c.count, !c[last + 1].isWhitespace else { return nil }
    let word = c[(last + 1)...].prefix { !$0.isWhitespace }
    if word.first?.isWholeNumber == true, word.allSatisfy({ $0.isWholeNumber || $0 == "." || $0 == "," }) { return nil }
    return position(last)
  }

  // MARK: Scanning

  private static func scan(_ prose: String) -> [Token] {
    let characters = Array(prose)
    var tokens: [Token] = []
    var text = ""
    func push(_ token: Token) {
      if !text.isEmpty { tokens.append(.text(text)) }
      text = ""
      tokens.append(token)
    }
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character == "\\", index + 1 < characters.count {
        text.append(character)
        text.append(characters[index + 1])
        index += 2
      } else if character == "`" {
        let length = MessageBlock.backtickRun(in: characters, at: index)
        if let close = codeSpanClose(in: characters, opening: index, length: length) {
          push(.code(String(characters[index..<close + length])))
          index = close + length
        } else {
          text += String(repeating: "`", count: length)
          index += length
        }
      } else if character == "$", let span = mathSpan(in: characters, at: index) {
        push(.math(latex: span.latex, isBlock: span.isBlock))
        index = span.end
      } else if character == "$", index + 1 < characters.count, characters[index + 1] == "$" {
        text += "$$"
        index += 2
      } else {
        text.append(character)
        index += 1
      }
    }
    if !text.isEmpty { tokens.append(.text(text)) }
    return tokens
  }

  /// The start of the run of the same length that closes the code span opened at `opening`.
  static func codeSpanClose(in characters: [Character], opening: Int, length: Int) -> Int? {
    var search = opening + length
    while search < characters.count {
      guard characters[search] == "`" else {
        search += 1
        continue
      }
      let candidate = MessageBlock.backtickRun(in: characters, at: search)
      if candidate == length { return search }
      search += candidate
    }
    return nil
  }

  /// `$$..$$` (anything between, newlines too) or `$..$`: the opening dollar is followed by a non-space, the closing one is
  /// the first unescaped dollar on the line, follows a non-space and is not followed by a digit (or another dollar).
  private static func mathSpan(in c: [Character], at start: Int) -> (latex: String, isBlock: Bool, end: Int)? {
    if start + 1 < c.count, c[start + 1] == "$" {
      var close = start + 2
      while close + 1 < c.count {
        if c[close] == "\\" {
          close += 2
        } else if c[close] == "$", c[close + 1] == "$" {
          let latex = String(c[start + 2..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
          return latex.isEmpty ? nil : (latex, true, close + 2)
        } else {
          close += 1
        }
      }
      return nil
    }
    guard start + 1 < c.count, !c[start + 1].isWhitespace else { return nil }
    var close = start + 1
    while close < c.count {
      if c[close] == "\n" { return nil }
      if c[close] == "\\" {
        close += 2
        continue
      }
      if c[close] == "$" { break }
      close += 1
    }
    guard close < c.count, !c[close - 1].isWhitespace else { return nil }
    if close + 1 < c.count, c[close + 1] == "$" || c[close + 1].isWholeNumber { return nil }
    return (String(c[start + 1..<close]), false, close + 1)
  }

  // MARK: Rewriting

  /// Every dollar sign of prose, escaped or not, becomes the small one.
  private static func defuse(_ text: String) -> String {
    let characters = Array(text)
    var result = ""
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character == "\\", index + 1 < characters.count {
        if characters[index + 1] == "$" {
          result.append(strayDollar)
        } else {
          result.append(character)
          result.append(characters[index + 1])
        }
        index += 2
      } else {
        result.append(character == "$" ? strayDollar : character)
        index += 1
      }
    }
    return result
  }

  /// LaTeX that survives Foundation's markdown parser, which runs before Textual's math pattern: backslashes are doubled and
  /// the characters markdown reads as markup are escaped, so the parser hands back the original LaTeX. Line breaks become
  /// spaces (LaTeX reads them so), and a no-break space that `MessageBlock.tyingUnits` put in is a space again.
  private static func protect(_ latex: String) -> String {
    var result = ""
    for character in latex {
      switch character {
      case "\\": result += "\\\\"
      case "*", "_", "[", "]", "~", "<", ">", "&", "`": result += "\\\(character)"
      case "\u{00A0}", "\n": result += " "
      default: result.append(character)
      }
    }
    return result
  }
}
