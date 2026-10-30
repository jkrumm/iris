import Foundation
import Testing

@testable import Iris

@Suite("PlainMarkdown")
struct PlainMarkdownTests {
  @Test("emphasis, code spans and heading marks disappear, the words stay")
  func inline() {
    let text = PlainMarkdown.text(from: "A **partial index** on `(repo)` and _more_.")
    #expect(text == "A partial index on (repo) and more.")
    #expect(PlainMarkdown.text(from: "## Plan\n\nBody") == "Plan\n\nBody")
  }

  @Test("lists keep a bullet or their number, nested items included")
  func lists() {
    #expect(PlainMarkdown.text(from: "- one\n- two") == "- one\n- two")
    #expect(PlainMarkdown.text(from: "1. first\n2. second") == "1. first\n2. second")
    #expect(PlainMarkdown.text(from: "Steps:\n\n1. **Build**\n2. Ship") == "Steps:\n\n1. Build\n2. Ship")
  }

  @Test("a link keeps its address, an autolink does not repeat it")
  func links() {
    #expect(
      PlainMarkdown.text(from: "See [the docs](https://example.com/x).") == "See the docs (https://example.com/x).")
    #expect(PlainMarkdown.text(from: "<https://example.com>") == "https://example.com")
  }

  @Test("a code fence is its code, with no fence marks")
  func codeBlock() {
    let text = PlainMarkdown.text(from: "Run:\n\n```sh\nmake check\n```\n\nDone.")
    #expect(text == "Run:\n\nmake check\n\nDone.")
  }

  @Test("table cells are tab-separated and rows on their own line")
  func table() {
    let text = PlainMarkdown.text(from: "| A | B |\n|-|-|\n| 1 | 2 |")
    #expect(text == "A\tB\n1\t2")
  }

  @Test("no markup character survives in a mixed reply")
  func mixed() {
    let text = PlainMarkdown.text(from: "# Title\n\n**Bold** and *italic*, `code`.\n\n> quoted\n\n- [x] item")
    #expect(!text.contains("**") && !text.contains("`") && !text.contains("# ") && !text.contains("> "))
    #expect(text.contains("Bold and italic, code."))
  }

  @Test("the memo's copy text: a blank transcript or reply is nothing to copy")
  func memoCopyText() {
    #expect(MemoFactory.memo("a", transcript: "  hi \n").plainTranscript == "hi")
    #expect(MemoFactory.memo("b", transcript: "   ").plainTranscript == nil)
    #expect(MemoFactory.memo("c").plainReply == nil)
    #expect(MemoFactory.memo("d", replyText: "**ok**").plainReply == "ok")
  }
}
