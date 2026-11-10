#if os(macOS)
  import SwiftUI
  import Testing

  @testable import IrisUI

  /// Cutting a reply into chunks must not move anything: each chunk is its own Textual view, so the gap above a chunk is
  /// rebuilt by `MessageContentView`. These lay the same markdown out as chunks and as one text run per Textual view (the
  /// layout before chunking) at 390 pt and compare the heights.
  @MainActor
  @Suite(.serialized)
  struct ChunkHeightTests {
    static let cases: [(name: String, markdown: String)] = [
      ("heading after paragraph", "Some intro text that sits above.\n\n## Section title\n\nBody under the section."),
      ("h1 after paragraph", "Intro line.\n\n# Big title\n\nBody."),
      ("h4 after paragraph", "Intro line.\n\n#### Small title\n\nBody."),
      ("paragraph after heading", "## Title\n\nThe paragraph below the heading."),
      ("list then paragraph", "Lead.\n\n- one\n- two\n- three\n\nParagraph after the list."),
      ("quote then paragraph", "Lead.\n\n> A quoted line\n> and a second one\n\nParagraph after the quote."),
      ("list then heading", "- one\n- two\n\n## Next\n\nText."),
      ("code then heading", "Text.\n\n```swift\nlet x = 1\n```\n\n## After code\n\nText."),
      ("two paragraphs", "First paragraph of the reply.\n\nSecond paragraph of the reply.\n\nThird."),
      ("fixture", ProseFixture.reply),
    ]

    @Test("a chunked reply is as tall as one Textual view per text run", arguments: Theme.TextRole.heightRoles)
    func chunkedEqualsUnchunked(role: Theme.TextRole) {
      let host = HostingMeasure()
      var report: [String] = []
      for (name, markdown) in Self.cases {
        let chunked = MessageBlock.tracked(markdown, chunked: true).blocks
        let whole = MessageBlock.tracked(markdown, chunked: false).blocks
        #expect(chunked.count > whole.count, "\(name) is cut")
        let one = host.height(
          of: MessageContentView(
            markdown: markdown, isStreaming: false, isBuffered: true, prepared: whole.identified, textRole: role))
        let many = host.height(
          of: MessageContentView(
            markdown: markdown, isStreaming: false, isBuffered: true, prepared: chunked.identified, textRole: role))
        report.append("\(name) [\(role)]: whole \(one) chunked \(many) (\(chunked.count) blocks)")
        #expect(abs(one - many) <= 1, "\(name): whole \(one) vs chunked \(many)")
      }
      print(report.joined(separator: "\n"))
    }
    @Test(
      "two neighbouring chunks of the fixture are as tall as the text joined", arguments: Theme.TextRole.heightRoles)
    func neighboursOfTheFixture(role: Theme.TextRole) {
      let host = HostingMeasure()
      var run: [String] = []
      var trajectory: [String] = []
      func check() {
        guard run.count > 1 else { return }
        for count in 2...run.count {
          let pieces = Array(run[(count - 2)...(count - 1)])
          let chunked = pieces.map { MessageBlock.markdown($0) }.identified
          let joined = [MessageBlock.markdown(pieces.joined(separator: "\n\n"))].identified
          let many = host.height(
            of: MessageContentView(
              markdown: "", isStreaming: false, isBuffered: true, prepared: chunked, textRole: role))
          let one = host.height(
            of: MessageContentView(markdown: "", isStreaming: false, isBuffered: true, prepared: joined, textRole: role)
          )
          if abs(one - many) > 1 {
            trajectory.append(
              "[\(role)] +chunk \(count): whole \(one) chunked \(many): \(pieces[1].prefix(50).debugDescription)"
            )
          }
          #expect(abs(one - many) <= 1, "\(pieces[1].prefix(50).debugDescription)")
        }
      }
      for block in MessageBlock.tracked(ProseFixture.reply, chunked: true).blocks {
        if case .markdown(let text) = block {
          run.append(text)
        } else {
          check()
          run = []
        }
      }
      check()
      print(trajectory.joined(separator: "\n"))
    }
  }

  extension Theme.TextRole {
    static let heightRoles: [Theme.TextRole] = [.callout, .footnote]
  }
#endif
