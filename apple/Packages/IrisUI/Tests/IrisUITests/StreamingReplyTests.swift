import Testing

@testable import IrisUI

struct StreamingReplyTests {
  /// `count` growing snapshots of `text`: prefix lengths evenly spaced, the last one the whole text.
  private func snapshots(of text: String, count: Int) -> [String] {
    let characters = Array(text)
    return (1...count).map { String(characters.prefix($0 * characters.count / count)) }
  }

  @Test("200 growing snapshots keep every finished block, and the final update is the one-shot split")
  func acceptance() {
    let full = ProseFixture.reply
    let all = snapshots(of: full, count: 200)
    #expect(all.last == full)
    var model = StreamingReplyModel()
    var previous: [IdentifiedBlock] = []
    for (index, snapshot) in all.enumerated() {
      let isLast = index == all.count - 1
      let blocks = model.update(markdown: snapshot, isStreaming: !isLast)
      if !isLast {
        // Every block but the last of the earlier snapshot is unchanged in the later one. The exceptions are all in the last
        // block of the earlier snapshot: a paragraph that turned into a table, and the stabilizer cutting or closing the
        // tail; they never reach the blocks before it. A stabilizer that dropped the whole tail leaves fewer blocks.
        let settled = previous.dropLast()
        #expect(blocks.count >= settled.count, "snapshot \(index) lost a finished block")
        #expect(Array(blocks.prefix(settled.count)) == Array(settled), "snapshot \(index) changed a finished block")
      }
      previous = blocks
    }
    #expect(previous == MessageBlock.split(full).identified)
  }

  @Test("a stream that is cut off renders the half text as it is, not stabilized")
  func cutOff() {
    let half = "Here is **bold and a [link](https://exa"
    var model = StreamingReplyModel()
    let streaming = model.update(markdown: half, isStreaming: true)
    #expect(streaming.last?.block == .markdown("Here is **bold and a link**"))
    let final = model.update(markdown: half, isStreaming: false)
    #expect(final == MessageBlock.split(half).identified)
    #expect(final.last?.block == .markdown(half))
  }

  @Test("a tail that is only a held-back marker leaves no empty block")
  func emptyTail() {
    var model = StreamingReplyModel()
    let blocks = model.update(markdown: "First.\n\n**", isStreaming: true)
    #expect(blocks.map(\.block) == [.markdown("First.\n\n")])
  }

  @Test("block ids stay when the text grows, and a diagram keeps its index after committed blocks")
  func identity() {
    var model = StreamingReplyModel()
    let diagram = "```mermaid\ngraph TD\nA-->B\n```"
    let text = "One.\n\n\(diagram)\n\nTwo.\n\nThree.\n"
    var seen: [[String]] = []
    for count in [8, 20, 40, text.count] {
      let blocks = model.update(markdown: String(text.prefix(count)), isStreaming: true)
      seen.append(blocks.map(\.id))
    }
    #expect(seen.last == ["text-0", "mermaid-0", "text-1", "text-2"])
    #expect(model.update(markdown: text, isStreaming: false).map(\.id) == ["text-0", "mermaid-0", "text-1"])
    #expect(seen[1].prefix(1) == ["text-0"])
  }

  @Test("a link reference definition keeps the document in one block per run, however it arrives")
  func referenceDefinition() {
    let text = "See [docs][d].\n\nSecond.\n\n[d]: https://example.com\n"
    var model = StreamingReplyModel()
    for count in stride(from: 5, through: text.count, by: 5) {
      model.update(markdown: String(text.prefix(count)), isStreaming: true)
    }
    let blocks = model.update(markdown: text, isStreaming: true)
    #expect(blocks.count == 1)
    #expect(model.update(markdown: text, isStreaming: false) == MessageBlock.split(text).identified)
  }

  @Test("text that is not an extension of the last one starts over")
  func rewrite() {
    var model = StreamingReplyModel()
    model.update(markdown: "One.\n\nTwo.\n\nThree.\n", isStreaming: true)
    let blocks = model.update(markdown: "Other.\n\nText.\n\nEnd.\n", isStreaming: true)
    #expect(blocks.map(\.block) == [.markdown("Other."), .markdown("Text."), .markdown("End.\n")])
  }
}
