import Testing

@testable import IrisUI

struct StreamingTailTests {
  /// (what has arrived, what is rendered)
  static let cases: [(String, String)] = [
    // Closers for unclosed emphasis, strike and code.
    ("Hello **wor", "Hello **wor**"),
    ("a *it", "a *it*"),
    ("__bold", "__bold__"),
    ("_it", "_it_"),
    ("~~gone", "~~gone~~"),
    ("use `code", "use `code`"),
    ("use ``co`de", "use ``co`de``"),
    ("**bold *it", "**bold *it***"),
    ("**bold*", "**bold**"),
    ("- item **bo", "- item **bo**"),
    ("**bold \n", "**bold**"),
    ("**bold `co", "**bold `co`**"),
    // A lone trailing marker with no text yet is dropped.
    ("Hello **", "Hello "),
    ("Hello _", "Hello "),
    ("Hello ~~", "Hello "),
    ("use `", "use "),
    ("foo**", "foo"),
    ("**`", ""),
    ("*", ""),
    // Links and images.
    ("[label](https://exa", "label"),
    ("[label](", "label"),
    ("[label]", "label"),
    ("[label", "label"),
    ("see [label](https://exa", "see label"),
    ("**[label](par", "**label**"),
    ("![alt](par", ""),
    ("Look: ![alt", "Look: "),
    ("Look: ![alt]", "Look: "),
    // Math that has not ended.
    ("Let $x^2", "Let "),
    ("Let $x$ and $y", "Let $x$ and "),
    ("Then $$a+b", "Then "),
    ("Then $$a+b\nmore", "Then "),
    // Fence openers being typed, headings with no text, table headers waiting for their delimiter row.
    ("text\n\n``", "text\n"),
    ("text\n\n~", "text\n"),
    ("para\n\n#", "para\n"),
    ("## ", ""),
    ("Intro\n\n| a | b |", "Intro\n"),
    ("Intro\n\n| a | b |\n", "Intro\n"),
    ("| a | b |\n|--", ""),
    ("| a | b |\n|:-", ""),
    ("one | two", ""),
    // A trailing partial HTML tag.
    ("a <di", "a "),
    ("a </", "a "),
    ("a <!", "a "),
  ]

  /// Text that is complete, or must not be touched.
  static let untouched: [String] = [
    "",
    "plain words",
    "**done** and *this* and ~~that~~ and `code`",
    "snake_case_name and 5 * 3 = 15",
    "* bullet\n* bullet **two**",
    "1. one\n2. two",
    "[a](https://example.com) and ![b](https://example.com/b.png)",
    "- [ ] task\n- [x] done",
    "Price $5 now and $12.50 later, or $5 and $10",
    "Let $x^2$ and $$y$$ end",
    "run `a $b` now",
    "1 < 2 and <https://example.com> and <b>bold</b>",
    "# Title\n\nbody",
    "```swift\nlet x = **1 [y\n",
    "```swift\nlet x = 1\n```\n\nafter `**` text",
    "~~~\n| a | b |\n~~~",
    "| a | b |\n|---|---|\n| 1 | 2 |",
    "`a|b` stays",
    "> quote with **bold**\n> more",
    "```",
  ]

  @Test("what is half written is finished or left out", arguments: cases)
  func stabilizes(arrived: String, rendered: String) {
    #expect(StreamingTail.stabilize(arrived) == rendered)
  }

  @Test("an unclosed fence and text inside a fence stay as they are", arguments: untouched)
  func untouchedText(markdown: String) {
    #expect(StreamingTail.stabilize(markdown) == markdown)
  }

  @Test("stabilizing twice changes nothing more", arguments: cases.map(\.0) + untouched)
  func idempotent(markdown: String) {
    let once = StreamingTail.stabilize(markdown)
    #expect(StreamingTail.stabilize(once) == once)
  }

  @Test("every prefix of the fixture stabilizes to something stable")
  func fixturePrefixes() {
    let reply = ProseFixture.reply
    var length = 0
    while length < reply.count {
      let prefix = String(reply.prefix(length))
      let once = StreamingTail.stabilize(prefix)
      #expect(StreamingTail.stabilize(once) == once, "prefix of \(length) characters")
      length += 37
    }
  }
}
