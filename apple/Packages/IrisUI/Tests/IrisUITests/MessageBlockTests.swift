import Testing

@testable import IrisUI

struct MessageBlockTests {
  @Test("code spans keep their spaces: single, double and longer backtick runs, matched by length")
  func codeSpansKeepSpaces() {
    let nbsp = "\u{00A0}"
    #expect(MessageBlock.tyingUnits(in: "run `sleep 2 s` for 2 s") == "run `sleep 2 s` for 2\(nbsp)s")
    #expect(MessageBlock.tyingUnits(in: "run ``sleep 2 s`` for 2 s") == "run ``sleep 2 s`` for 2\(nbsp)s")
    // A single backtick inside a double span does not end it.
    #expect(MessageBlock.tyingUnits(in: "``a ` 2 s`` then 2 s") == "``a ` 2 s`` then 2\(nbsp)s")
    #expect(MessageBlock.tyingUnits(in: "```x 2 s``` and 2 s") == "```x 2 s``` and 2\(nbsp)s")
    // Two spans on a line, prose between them.
    #expect(MessageBlock.tyingUnits(in: "`1 s` is 1 s, ``2 s`` is 2 s") == "`1 s` is 1\(nbsp)s, ``2 s`` is 2\(nbsp)s")
  }

  @Test("a backtick run with no matching close is literal text, so the prose after it is still tied")
  func unmatchedBackticks() {
    let nbsp = "\u{00A0}"
    #expect(MessageBlock.tyingUnits(in: "a ` b 2 s") == "a ` b 2\(nbsp)s")
    #expect(MessageBlock.tyingUnits(in: "``a` 2 s") == "``a` 2\(nbsp)s")
    // A run of another length is no close either.
    #expect(MessageBlock.tyingUnits(in: "`a`` 2 s") == "`a`` 2\(nbsp)s")
  }

  @Test("fenced code, backtick and tilde, is left alone and prose around it is tied")
  func fencedBlocksKeepSpaces() {
    let nbsp = "\u{00A0}"
    #expect(
      MessageBlock.tyingUnits(in: "1 s\n```sh\nsleep 2 s\n```\n3 s")
        == "1\(nbsp)s\n```sh\nsleep 2 s\n```\n3\(nbsp)s")
    #expect(
      MessageBlock.tyingUnits(in: "~~~\nsleep 2 s\n~~~\n3 s") == "~~~\nsleep 2 s\n~~~\n3\(nbsp)s")
  }

  @Test("the space between a number and its unit is a no-break space, in prose only")
  func tiesUnits() {
    let nbsp = "\u{00A0}"
    #expect(
      MessageBlock.tyingUnits(in: "It took *2 s* and 38 MB, 12 % more")
        == "It took *2\(nbsp)s* and 38\(nbsp)MB, 12\(nbsp)% more")
    #expect(MessageBlock.tyingUnits(in: "2,5 min and 40 ms") == "2,5\(nbsp)min and 40\(nbsp)ms")
    // A word that merely starts like a unit, a number with no unit, and code are left alone.
    #expect(MessageBlock.tyingUnits(in: "3 stories and 2 of them") == "3 stories and 2 of them")
    #expect(MessageBlock.tyingUnits(in: "run `sleep 2 s` now") == "run `sleep 2 s` now")
    #expect(MessageBlock.tyingUnits(in: "```\nwait 2 s\n```\nthen 2 s") == "```\nwait 2 s\n```\nthen 2\(nbsp)s")
    #expect(MessageBlock.split("took 2 s") == [.markdown("took 2\(nbsp)s")])
  }

  @Test("plain markdown stays one block")
  func plain() {
    #expect(MessageBlock.split("Hello **world**\n\n- a\n- b") == [.markdown("Hello **world**\n\n- a\n- b")])
    #expect(MessageBlock.split("  \n") == [])
  }

  @Test("a mermaid fence becomes its own block, indexed from zero in document order")
  func mermaid() {
    let reply = "Intro\n\n```mermaid\ngraph TD\nA-->B\n```\nMiddle\n```Mermaid\nflowchart LR\n```\nEnd"
    #expect(
      MessageBlock.split(reply) == [
        .markdown("Intro\n"),
        .mermaid(index: 0, source: "```mermaid\ngraph TD\nA-->B\n```"),
        .markdown("Middle"),
        .mermaid(index: 1, source: "```Mermaid\nflowchart LR\n```"),
        .markdown("End"),
      ])
  }

  @Test("a mermaid fence inside another fence is that fence's text and takes no index")
  func nestedMermaid() {
    let reply = "````md\n```mermaid\ngraph TD\n```\n````\n\n~~~mermaid\nA-->B\n~~~"
    #expect(
      MessageBlock.split(reply) == [
        .markdown("````md\n```mermaid\ngraph TD\n```\n````\n"),
        .mermaid(index: 0, source: "~~~mermaid\nA-->B\n~~~"),
      ])
  }

  @Test("an unclosed mermaid fence runs to the end; an unclosed code fence stays text")
  func unclosed() {
    #expect(MessageBlock.split("```mermaid\ngraph TD") == [.mermaid(index: 0, source: "```mermaid\ngraph TD")])
    #expect(MessageBlock.split("```swift\nlet x = 1") == [.markdown("```swift\nlet x = 1")])
  }

  @Test("a fence closes only on the same character, at least as long, with nothing after it")
  func closing() {
    let reply = "```mermaid\nA\n~~~\n``` x\n```"
    #expect(MessageBlock.split(reply) == [.mermaid(index: 0, source: reply)])
  }

  @Test("a pipe table becomes a table block with outer pipes, escapes and short rows handled")
  func table() {
    let reply = "Before\n\n| Name | Note |\n|:-|-:|\n| a | x \\| y |\n| b |\n\nAfter"
    #expect(
      MessageBlock.split(reply) == [
        .markdown("Before\n"),
        .table(
          MarkdownTable(
            headers: ["Name", "Note"], rows: [["a", "x | y"], ["b", ""]], alignments: [.leading, .trailing])),
        .markdown("\nAfter"),
      ])
  }

  @Test("a table without outer pipes parses; a pipe in prose or inside a code fence is not a table")
  func tableEdges() {
    #expect(
      MessageBlock.split("A | B\n--|--\n1 | 2")
        == [.table(MarkdownTable(headers: ["A", "B"], rows: [["1", "2"]]))])
    #expect(MessageBlock.split("a | b\nplain line") == [.markdown("a | b\nplain line")])
    let fenced = "```\n| A | B |\n|-|-|\n| 1 | 2 |\n```"
    #expect(MessageBlock.split(fenced) == [.markdown(fenced)])
  }

  @Test("the delimiter row's colons set each column's alignment; none means leading")
  func tableAlignments() {
    let reply = "| A | B | C | D |\n|:--|:-:|--:|---|\n| 1 | 2 | 3 | 4 |"
    #expect(
      MessageBlock.split(reply)
        == [
          .table(
            MarkdownTable(
              headers: ["A", "B", "C", "D"], rows: [["1", "2", "3", "4"]],
              alignments: [.leading, .center, .trailing, .leading]))
        ])
  }

  @Test("a table built without alignments is all leading")
  func defaultAlignments() {
    #expect(MarkdownTable(headers: ["A", "B"], rows: []).alignments == [.leading, .leading])
  }

  @Test("a delimiter row of another width is no table")
  func widthMismatch() {
    #expect(MessageBlock.split("| A | B |\n|-|\n| 1 | 2 |") == [.markdown("| A | B |\n|-|\n| 1 | 2 |")])
  }

  @Test("a diagram keeps its identity when a table or text is put above it")
  func stableIdentity() {
    let plain = MessageBlock.split("```mermaid\ngraph TD\n```\nEnd").identified.map(\.id)
    #expect(plain == ["mermaid-0", "text-0"])

    let withText = MessageBlock.split("Intro\n\n```mermaid\ngraph TD\n```\nEnd").identified.map(\.id)
    #expect(withText == ["text-0", "mermaid-0", "text-1"])

    let withTable = MessageBlock.split("| a |\n|-|\n| 1 |\n\n```mermaid\ngraph TD\n```").identified.map(\.id)
    #expect(withTable == ["table-0", "mermaid-0"])
  }

  @Test("every block of a reply has its own id")
  func uniqueIdentity() {
    let diagram = "```mermaid\ngraph TD\n```"
    let table = "| a |\n|-|\n| 1 |"
    let source = ["A", diagram, table, diagram, table, "End"].joined(separator: "\n\n")
    let ids = MessageBlock.split(source).identified.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(ids.contains("mermaid-1") && ids.contains("table-1"))
  }

  // MARK: Chunks

  private func texts(_ markdown: String) -> [String] {
    MessageBlock.tracked(markdown, chunked: true).blocks.compactMap {
      if case .markdown(let text) = $0 { text } else { nil }
    }
  }

  @Test("the public split keeps a text run as one block; only the streaming split chunks")
  func publicSplitIsUnchunked() {
    #expect(MessageBlock.split("First.\n\n## Heading\n\nBody.") == [.markdown("First.\n\n## Heading\n\nBody.")])
  }

  @Test("a blank line before a paragraph or an ATX heading at column 0 cuts the text into chunks")
  func chunkBoundaries() {
    #expect(texts("First.\n\nSecond.") == ["First.", "Second."])
    #expect(texts("First.\n\n\n\nSecond.") == ["First.", "Second."])
    #expect(texts("First.\n\n## Heading\n\nBody.") == ["First.", "## Heading", "Body."])
    #expect(texts("- a\n- b\n\nAfter") == ["- a\n- b", "After"])
    #expect(texts("> quote\n\nAfter") == ["> quote", "After"])
    #expect(texts("```sh\nls\n```\n\nAfter") == ["```sh\nls\n```", "After"])
    #expect(texts("A\nsame paragraph\n\nB") == ["A\nsame paragraph", "B"])
    #expect(texts("Price is 3.14 now\n\n3.14 is pi") == ["Price is 3.14 now", "3.14 is pi"])
  }

  @Test(
    "no cut without a blank line, and none before a list marker, quote, table row, HTML, link, indent, rule or fence")
  func chunkNonBoundaries() {
    let nonBoundaries = [
      "A\nB",
      "A\n\n- b",
      "A\n\n* b",
      "A\n\n+ b",
      "A\n\n-",
      "1. a\n\n2. b",
      "A\n\n3) b",
      "A\n\n> quote",
      "A\n\n| x | y |",
      "A\n\n<div>b</div>",
      "A\n\n[b](https://example.com)",
      "A\n\n    indented",
      "A\n\n\tindented",
      "A\n\n---",
      "A\n\n***",
      "A\n\n- - -",
      "A\n\n```swift\nlet x = 1\n```",
      "A\n\n~~~\nx\n~~~",
    ]
    for markdown in nonBoundaries {
      #expect(texts(markdown).count == 1, "\(markdown.debugDescription) stays one block")
    }
  }

  @Test("list and quote continuations, indented code and nested items stay with their block")
  func chunkContinuations() {
    let nested = "- a\n  - b\n\nAfter"
    #expect(texts(nested) == [nested])
    let loose = "- a\n\n  more of a\n\nAfter"
    #expect(texts(loose) == [loose])
    let code = "    let x = 1\n\nAfter"
    #expect(texts(code) == [code])
    let rule = "Above.\n\n---\n\nBelow."
    #expect(texts(rule) == [rule])
    let continued = "1. a\n\n   para in a\n\n2. b"
    #expect(texts(continued) == [continued])
  }

  @Test("blank lines inside a fence or a display formula never cut")
  func chunkInsideFenceAndMath() {
    let fenced = "Intro\n\n```\nline\n\nOther\n\n# not a heading\n```\n\nAfter"
    #expect(texts(fenced) == ["Intro\n\n```\nline\n\nOther\n\n# not a heading\n```", "After"])
    let unclosed = "Intro\n\n```\nline\n\nOther"
    #expect(texts(unclosed) == [unclosed])
    let math = "Intro\n\n$$\na\n\nb\n$$\n\nAfter"
    #expect(texts(math) == ["Intro", "$$\na\n\nb\n$$", "After"])
  }

  @Test("a document with a link reference definition is one block per text run")
  func chunkReferenceDefinition() {
    let reply = "See [docs][d].\n\nSecond.\n\n[d]: https://example.com\n"
    #expect(texts(reply).count == 1)
    #expect(texts("A\n\nB\n\n   [d]: x").count == 1)
    #expect(texts("A\n\n[^1]: note").count == 1)
    #expect(texts("A\n\nB [not a definition]").count == 2)
  }

  @Test("chunks sit around tables and diagrams, and the chunk after a cut starts on its first non-blank line")
  func chunkAroundStructure() {
    let reply = "One.\n\nTwo.\n\n| a |\n|-|\n| 1 |\n\nThree.\n\nFour."
    let blocks = MessageBlock.tracked(reply, chunked: true)
    #expect(
      blocks.blocks == [
        .markdown("One."), .markdown("Two.\n"), .table(MarkdownTable(headers: ["a"], rows: [["1"]])),
        .markdown("\nThree."), .markdown("Four."),
      ])
    #expect(blocks.startLines == [0, 2, 4, 7, 10])
  }

  @Test("the unchunked split and the partial-tail split differ only where asked")
  func chunkOptions() {
    let reply = "One.\n\nTwo.\n\nThr"
    #expect(MessageBlock.tracked(reply, chunked: false).blocks == [.markdown(reply)])
    #expect(
      MessageBlock.tracked(reply, chunked: true, partialTail: true).blocks == [
        .markdown("One."), .markdown("Two.\n\nThr"),
      ])
    #expect(MessageBlock.split(reply, startingMermaidIndex: 3) == MessageBlock.split(reply))
    let diagram = "```mermaid\nA-->B\n```"
    #expect(MessageBlock.split(diagram, startingMermaidIndex: 3) == [.mermaid(index: 3, source: diagram)])
  }

  @Test("artifact fences become blocks numbered per kind like the server's index, between Mermaid and code fences")
  func mixedFences() {
    let chart = "```iris-show\n{\"type\":\"chart\"}\n```"
    let diagram = "```mermaid\nA-->B\n```"
    let doc = "```iris-doc title=\"Weekly report\" format=markdown\n# Week\n```"
    let table = "~~~IRIS-SHOW\n{\"type\":\"table\"}\n~~~"
    let code = "```json\n{\"type\":\"stat\"}\n```"
    let html = "````iris-doc format=html\n<p>Hi</p>\n```\n````"
    let reply = [
      "Intro", chart, diagram, "Then", doc, table, code, html, "````md\n```iris-show\n{}\n```\n````",
    ].joined(separator: "\n")
    #expect(
      MessageBlock.split(reply) == [
        .markdown("Intro"),
        .artifact(.show, index: 0, source: chart),
        .mermaid(index: 0, source: diagram),
        .markdown("Then"),
        .artifact(.doc, index: 0, source: doc),
        .artifact(.show, index: 1, source: table),
        .markdown(code),
        .artifact(.doc, index: 1, source: html),
        // A fence inside another fence is that fence's text and takes no index.
        .markdown("````md\n```iris-show\n{}\n```\n````"),
      ])
  }

  @Test("an artifact fence keeps its index when the stream commits the blocks above it")
  func artifactIndexAcrossCommits() {
    let reply = "```iris-show\n{}\n```\n\nText.\n\n```iris-show\n{}\n```\n\nMore."
    var model = StreamingReplyModel()
    var streamed: [IdentifiedBlock] = []
    for end in reply.indices.dropFirst() {
      streamed = model.update(markdown: String(reply[..<end]), isStreaming: true)
    }
    streamed = model.update(markdown: reply, isStreaming: true)
    let ids = streamed.map(\.id).filter { $0.hasPrefix("artifact") }
    #expect(ids == ["artifact-show-0", "artifact-show-1"])
    #expect(model.update(markdown: reply, isStreaming: false) == MessageBlock.split(reply).identified)
  }

  @Test("an unclosed artifact fence runs to the end, like the server's reading")
  func unclosedArtifact() {
    #expect(MessageBlock.split("```iris-doc\n# Draft") == [.artifact(.doc, index: 0, source: "```iris-doc\n# Draft")])
  }
}
