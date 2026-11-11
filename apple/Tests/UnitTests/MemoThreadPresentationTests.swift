import Foundation
import IrisCore
import IrisUI
import Testing

@testable import Iris

@Suite("Memo thread presentation")
struct MemoThreadPresentationTests {
  private func memo(_ id: String, mode: MemoMode, threadId: String?, deleted: Bool = false) -> Memo {
    var memo = MemoFactory.memo(id, mode: mode)
    memo.threadId = threadId
    memo.deletedAt = deleted ? MemoFactory.now : nil
    return memo
  }

  @Test(
    "a turn into another memo's session carries the thread marker; a memo in its own session, a transcript or a deleted one does not"
  )
  func continuesThread() {
    #expect(memo("b", mode: .hermes, threadId: "a").continuesThread)
    #expect(!memo("a", mode: .hermes, threadId: "a").continuesThread, "act gives every Hermes memo its own session id")
    #expect(!memo("d", mode: .transcribe, threadId: nil).continuesThread)
    #expect(!memo("e", mode: .hermes, threadId: "e", deleted: true).continuesThread)
    #expect(!memo("f", mode: .hermes, threadId: "z", deleted: true).continuesThread)
  }

  @Test(
    "the sample data is shaped like the server's: own-session memos carry their id, only the follow-ups carry the thread marker"
  )
  func sampleThreadIDs() {
    let details = SampleData.details(now: MemoFactory.now)
    let opening = details.map(\.memo).filter(\.continuesThread).map(\.id).sorted()
    #expect(opening == [SampleData.chatFollowUpID, SampleData.hermesFollowUpID].sorted())
    let own = details.map(\.memo).filter { $0.threadId == $0.id }
    #expect(own.count >= 4, "acted Hermes memos are in their own session")
    #expect(own.allSatisfy { !$0.continuesThread && $0.destinationRef != nil })
  }

  @Test("a conversation entry becomes the turn the screens draw, with the memo's progress, caption and error")
  func turnMapping() {
    var failed = memo("f", mode: .hermes, threadId: nil)
    failed.state = .failed
    failed.error = nil
    let entry = ConversationEntry(id: "f.failed", memo: failed, date: nil, kind: .failed(nil))
    #expect(ConversationTurn(entry).content == .failed(String(localized: "This turn failed.")))
    #expect(ConversationTurn(entry).memoID == "f")

    var running = memo("r", mode: .hermes, threadId: nil)
    running.state = .routed
    let pending = ConversationTurn(ConversationEntry(id: "r.pending", memo: running, date: nil, kind: .pending))
    #expect(pending.content == .pending(running.stepProgress, caption: running.pendingCaption))
    #expect(pending.id == "r.pending")

    let answer = ConversationTurn(
      ConversationEntry(id: "r.reply", memo: running, date: MemoFactory.now, kind: .reply("**Hi**")))
    #expect(answer.content == .assistant("**Hi**", mermaid: [:]) && answer.date == MemoFactory.now)
  }

  @Test("a memo's reply artifacts are keyed by kind and per-kind index, as assets of the memo")
  func artifactMapping() {
    var withArtifacts = memo("m", mode: .hermes, threadId: "m")
    withArtifacts.replyArtifacts = [
      ReplyArtifact(index: 0, kind: .show, title: "Chart", assetId: "s0", bytes: 10),
      ReplyArtifact(index: 1, kind: .show, assetId: "s1", bytes: 20),
      ReplyArtifact(index: 0, kind: .doc, title: "Report", format: .html, assetId: "d0", bytes: 30),
    ]
    let assets = withArtifacts.artifactAssets
    #expect(assets.count == 3)
    let chart = ArtifactAsset(
      ref: ReplyAssetRef(memoID: "m", assetID: "s0"), kind: .show, index: 0, title: "Chart", format: nil, bytes: 10)
    #expect(assets[chart.key] == chart)
    #expect(assets[.init(kind: .show, index: 1)]?.ref == ReplyAssetRef(memoID: "m", assetID: "s1"))
    #expect(assets[.init(kind: .doc, index: 0)]?.format == .html && assets[.init(kind: .doc, index: 0)]?.bytes == 30)
    #expect(memo("n", mode: .hermes, threadId: "n").artifactAssets.isEmpty)

    let answer = ConversationTurn(ConversationEntry(id: "m.reply", memo: withArtifacts, date: nil, kind: .reply("x")))
    #expect(answer.content == .assistant("x", mermaid: [:], artifacts: assets))
  }

  @Test("the sample artifact thread lists a chart, a table and a document, each the size of its fake file")
  func sampleArtifacts() throws {
    let all = SampleData.details(now: MemoFactory.now).map(\.memo)
    let memo = try #require(all.first { $0.id == SampleData.artifactThreadID })
    #expect(memo.replyArtifacts.map(\.kind) == [.show, .show, .doc])
    for artifact in memo.replyArtifacts {
      #expect(SampleData.artifactFile(assetID: artifact.assetId)?.count == artifact.bytes)
    }
    let blocks = MessageBlock.split(try #require(memo.replyText))
    #expect(blocks.filter { if case .artifact = $0 { true } else { false } }.count == 3)
  }

  @Test("the media source names a reply's image under the memo, authenticated and kept for good")
  func assetRequest() throws {
    let source = AuthenticatedMediaSource(baseURL: URL(string: "https://iris.example.com")!, bearerToken: "tok")
    let request = try #require(source.asset(memoID: "m", assetID: "a"))
    #expect(request.url.absoluteString == "https://iris.example.com/v1/memos/m/assets/a")
    #expect(request.headers == ["Authorization": "Bearer tok"])
    #expect(request.isReusable && request.cacheName == "m.a.asset")
    #expect(UnavailableMediaSource().asset(memoID: "m", assetID: "a") == nil)
  }
}
