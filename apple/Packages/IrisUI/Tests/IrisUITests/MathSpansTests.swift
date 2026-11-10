import Foundation
import Testing
import Textual

@testable import IrisUI

@MainActor
struct MathSpansTests {
  private func math(_ markdown: String) -> [MathSpans.Token] {
    MathSpans.tokens(in: markdown).filter { if case .math = $0 { true } else { false } }
  }

  /// The LaTeX Textual's math extension ends up with, read back from the attachments' descriptions (`$..$` or `$$..$$`).
  private func rendered(_ markdown: String) throws -> [String] {
    let parsed = try AttributedStringMarkdownParser.markdown(syntaxExtensions: [.math]).attributedString(for: markdown)
    return parsed.runs.compactMap { $0.textual.attachment?.description }
  }

  private func roundTrip(_ latex: String, block: Bool = false) throws -> [String] {
    let markdown = try #require(MathSpans.prepare(block ? "$$\(latex)$$" : "$\(latex)$"))
    return try rendered(markdown)
  }

  @Test("prices stay text")
  func prices() {
    #expect(MathSpans.prepare("It costs $5 and $10 in total.") == nil)
    #expect(MathSpans.prepare("From $5 to $10, or $ 5 and 5 $ later") == nil)
    #expect(MathSpans.prepare("a price of $5") == nil)
    #expect(MathSpans.prepare("no dollars at all") == nil)
    #expect(MathSpans.prepare("a lone $$ pair") == nil)
  }

  @Test("an inline and a block span are found; the closing dollar may not touch a digit")
  func validSpans() {
    #expect(math("so $E = mc^2$ holds") == [.math(latex: "E = mc^2", isBlock: false)])
    #expect(math("$$\\int_0^1 x\\,dx$$") == [.math(latex: "\\int_0^1 x\\,dx", isBlock: true)])
    #expect(math("$$\n a + b\n$$") == [.math(latex: "a + b", isBlock: true)])
    #expect(math("$x$5").isEmpty)
    #expect(math("$ x$").isEmpty)
    #expect(math("$x $").isEmpty)
    #expect(math("$x\ny$").isEmpty)
    #expect(math("pay \\$5 or \\$7").isEmpty)
  }

  @Test("a span next to prices is still found, the prices stay text")
  func mixed() throws {
    let prepared = try #require(MathSpans.prepare("It costs $5 and $10, and $x^2$ is a square."))
    #expect(prepared == "It costs \u{FE69}5 and \u{FE69}10, and $x^2$ is a square.")
    #expect(try rendered(prepared) == ["$x^2$"])
  }

  @Test("fenced code and code spans are ignored")
  func codeIgnored() {
    #expect(MathSpans.prepare("```sh\necho $HOME and $PATH$\n```") == nil)
    #expect(MathSpans.prepare("~~~\n$x$\n~~~") == nil)
    #expect(MathSpans.prepare("run `echo $x$` now") == nil)
    #expect(MathSpans.prepare("run ``a ` $x$`` now") == nil)
    let prepared = MathSpans.prepare("```\n$x$\n```\nthen $y$ and `$z$` and $1")
    #expect(prepared == "```\n$x$\n```\nthen $y$ and `$z$` and \u{FE69}1")
  }

  @Test("stray dollars in a math block, escaped or not, cannot be paired by Textual")
  func strayDollars() throws {
    let prepared = try #require(MathSpans.prepare("Costs \\$5 and $7, then $a+b$ and a lone $ here."))
    #expect(!prepared.replacingOccurrences(of: "$a+b$", with: "").contains("$"))
    #expect(try rendered(prepared) == ["$a+b$"])
  }

  @Test("LaTeX survives Foundation's markdown parser unchanged")
  func protectionRoundTrip() throws {
    #expect(try roundTrip("\\frac{a}{b}") == ["$\\frac{a}{b}$"])
    #expect(try roundTrip("\\{ x \\}") == ["$\\{ x \\}$"])
    #expect(try roundTrip("a \\\\ b") == ["$a \\\\ b$"])
    #expect(try roundTrip("x_1 + y_1") == ["$x_1 + y_1$"])
    #expect(try roundTrip("a * b * c") == ["$a * b * c$"])
    #expect(
      try roundTrip("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}", block: true) == [
        "$$\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}$$"
      ])
    #expect(try roundTrip("\\left[ x \\right](y)") == ["$\\left[ x \\right](y)$"])
    #expect(try roundTrip("\\$5") == ["$\\$5$"])
  }

  @Test("a block span over several lines becomes one line")
  func multilineBlock() throws {
    #expect(try rendered(try #require(MathSpans.prepare("$$\na_1\n+ b_1\n$$"))) == ["$$a_1 + b_1$$"])
  }

  @Test("the no-break space of a number and its unit is a space again inside math, and stays outside")
  func spaceRestored() throws {
    let tied = MessageBlock.split("took 2 s and $t = 2 s$ in 38 MB")
    let text = try #require(
      tied.first.flatMap { block -> String? in
        if case .markdown(let text) = block { text } else { nil }
      })
    #expect(text.contains("took 2\u{00A0}s"))
    let prepared = try #require(MathSpans.prepare(text))
    #expect(try rendered(prepared) == ["$t = 2 s$"])
    #expect(prepared.contains("38\u{00A0}MB"))
  }
}
