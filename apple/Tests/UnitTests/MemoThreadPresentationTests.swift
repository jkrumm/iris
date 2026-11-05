import Foundation
import IrisCore
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
    "a turn into another memo's session opens the thread; a memo in its own session, a transcript or a deleted one keeps the detail"
  )
  func opensThread() {
    #expect(memo("b", mode: .hermes, threadId: "a").opensThread)
    #expect(!memo("a", mode: .hermes, threadId: "a").opensThread, "act gives every Hermes memo its own session id")
    #expect(!memo("d", mode: .transcribe, threadId: nil).opensThread)
    #expect(!memo("e", mode: .hermes, threadId: "e", deleted: true).opensThread)
    #expect(!memo("f", mode: .hermes, threadId: "z", deleted: true).opensThread)
  }

  @Test(
    "the sample data is shaped like the server's: own-session memos carry their id, only the follow-ups open a thread")
  func sampleThreadIDs() {
    let details = SampleData.details(now: MemoFactory.now)
    let opening = details.map(\.memo).filter(\.opensThread).map(\.id).sorted()
    #expect(opening == [SampleData.chatFollowUpID, SampleData.hermesFollowUpID].sorted())
    let own = details.map(\.memo).filter { $0.threadId == $0.id }
    #expect(own.count >= 4, "acted Hermes memos are in their own session")
    #expect(own.allSatisfy { !$0.opensThread && $0.destinationRef != nil })
  }

  @Test("the route carries the thread id and the memo's headline as the title until the thread loads")
  func route() {
    var thread = memo("b", mode: .hermes, threadId: "a")
    thread.summary = MemoSummary(headline: "Headline", detail: "d", spoken: "s")
    #expect(thread.threadRoute == ThreadRoute(id: "a", title: "Headline"))
    #expect(memo("x", mode: .hermes, threadId: nil).threadRoute == nil)
  }

  @Test("the media source names a reply's image under the memo, authenticated and kept for good")
  func assetRequest() throws {
    let source = AuthenticatedMediaSource(baseURL: URL(string: "https://iris.example.com")!, bearerToken: "tok")
    let request = try #require(source.asset(memoID: "m", assetID: "a"))
    #expect(request.url.absoluteString == "https://iris.example.com/v1/memos/m/assets/a")
    #expect(request.headers == ["Authorization": "Bearer tok"])
    #expect(request.isReusable && request.cacheName == "m.a.png")
    #expect(UnavailableMediaSource().asset(memoID: "m", assetID: "a") == nil)
  }
}
