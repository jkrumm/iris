import Foundation
import Testing

@testable import Iris

@Suite("ReplyMarkdown")
struct ReplyMarkdownTests {
  @Test("emphasis, code spans and links become styled runs, the markup disappears")
  func inlineStyles() throws {
    let text = ReplyMarkdown.attributed("A **partial index** on `(repo)` — see [docs](https://example.com/x).")
    #expect(String(text.characters) == "A partial index on (repo) — see docs.")
    let strong = try #require(text.runs.first { $0.inlinePresentationIntent == .stronglyEmphasized })
    #expect(String(text[strong.range].characters) == "partial index")
    #expect(text.runs.contains { $0.inlinePresentationIntent == .code })
    #expect(text.runs.contains { $0.link == URL(string: "https://example.com/x") })
  }

  @Test("line breaks survive, and unparseable text falls back to itself")
  func whitespace() {
    #expect(String(ReplyMarkdown.attributed("one\ntwo").characters) == "one\ntwo")
    #expect(String(ReplyMarkdown.attributed("").characters).isEmpty)
  }
}
