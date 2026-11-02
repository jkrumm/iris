import Testing

@testable import IrisUI

struct MessageBlockTests {
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
        .table(MarkdownTable(headers: ["Name", "Note"], rows: [["a", "x | y"], ["b", ""]])),
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
}
