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

  @Test("a chat opens its thread, a continued turn opens its thread, a Hermes memo in its own session does not")
  func opensThread() {
    #expect(memo("a", mode: .chat, threadId: "a").opensThread)
    #expect(memo("b", mode: .hermes, threadId: "a").opensThread)
    #expect(memo("c", mode: .tab, threadId: "a").opensThread)
    #expect(!memo("a", mode: .hermes, threadId: "a").opensThread)
    #expect(!memo("d", mode: .chat, threadId: nil).opensThread)
    #expect(!memo("e", mode: .chat, threadId: "e", deleted: true).opensThread)
  }

  @Test("the route carries the thread id and the memo's headline as the title until the thread loads")
  func route() {
    var thread = memo("b", mode: .hermes, threadId: "a")
    thread.summary = MemoSummary(headline: "Headline", detail: "d", spoken: "s")
    #expect(thread.threadRoute == ThreadRoute(id: "a", title: "Headline"))
    #expect(memo("x", mode: .chat, threadId: nil).threadRoute == nil)
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
