import IrisCore
import IrisTelemetry
import Testing

@testable import Iris

private struct Missing: Error {}

@MainActor
@Suite("ConversationRouter")
struct ConversationRouterTests {
  private final class Logged {
    var events: [(String, [String: AttributeValue])] = []
  }

  private func router(_ logged: Logged = Logged()) -> ConversationRouter {
    ConversationRouter(log: { name, attributes in logged.events.append((name, attributes)) })
  }

  private func request(_ router: ConversationRouter, _ id: String, focus: ComposerFocus = .none)
    -> ConversationRouter.Request?
  {
    router.open(ConversationLink(memoID: id, focus: focus))
    return router.pending
  }

  @Test("a memo History holds opens without a fetch, and the pending request is cleared")
  func local() async throws {
    let router = router()
    let memo = MemoFactory.memo("m1")
    let pending = try #require(request(router, "m1", focus: .keyboard))
    let opened = await router.resolve(
      pending, isConfigured: true, local: { $0 == "m1" ? memo : nil }, fetch: { _ in throw Missing() })
    #expect(opened == .init(memo: memo, focus: .keyboard))
    #expect(router.pending == nil)
    #expect(router.takeFocus(forAnyOf: ["m1"]) == .keyboard)
    #expect(router.takeFocus(forAnyOf: ["m1"]) == .none, "the focus is applied once")
  }

  @Test("a memo History does not hold is fetched")
  func fetched() async throws {
    let router = router()
    let memo = MemoFactory.memo("m2")
    let pending = try #require(request(router, "m2"))
    let opened = await router.resolve(pending, isConfigured: true, local: { _ in nil }, fetch: { _ in memo })
    #expect(opened?.memo == memo)
  }

  @Test("not configured, not found and deleted are dropped and logged")
  func dropped() async throws {
    let logged = Logged()
    let router = router(logged)
    var deleted = MemoFactory.memo("m3")
    deleted.deletedAt = MemoFactory.now
    let gone = deleted
    for (configured, fetch) in [
      (false, { @MainActor (_: String) async throws -> Memo in MemoFactory.memo("m3") }),
      (true, { _ in throw Missing() }),
      (true, { _ in gone }),
    ] {
      let pending = try #require(request(router, "m3"))
      let opened = await router.resolve(pending, isConfigured: configured, local: { _ in nil }, fetch: fetch)
      #expect(opened == nil)
      #expect(router.pending == nil)
    }
    #expect(logged.events.count == 3)
    #expect(logged.events.allSatisfy { $0.0 == "ui.route" && $0.1["opened"] == .bool(false) })
  }

  @Test("a newer request survives the resolution of an older one")
  func newerWins() async throws {
    let router = router()
    let old = try #require(request(router, "old"))
    let newer = try #require(request(router, "new"))
    let opened = await router.resolve(
      old, isConfigured: true, local: { _ in MemoFactory.memo("old") }, fetch: { _ in throw Missing() })
    #expect(opened == nil)
    #expect(router.pending == newer)
  }

  @Test("the request waits until something resolves it")
  func pendingSurvives() throws {
    let router = router()
    router.open(ConversationLink(memoID: "m4", focus: .voice))
    #expect(router.pending?.link == ConversationLink(memoID: "m4", focus: .voice))
  }
}

@MainActor
@Suite("ConversationRouter voice reply")
struct ConversationRouterVoiceTests {
  private func opened(_ router: ConversationRouter, threadID: String?, focus: ComposerFocus) async throws
    -> ConversationRouter.Opened
  {
    var memo = MemoFactory.memo("m1")
    memo.threadId = threadID
    router.open(ConversationLink(memoID: "m1", focus: focus))
    let pending = try #require(router.pending)
    let result = await router.resolve(pending, isConfigured: true, local: { _ in memo }, fetch: { _ in memo })
    return try #require(result)
  }

  @Test("the voice focus starts a take bound to the memo's thread, once per request")
  func startsOnce() async throws {
    let router = ConversationRouter(log: { _, _ in })
    let opened = try await opened(router, threadID: "t1", focus: .voice)
    var started: [String] = []
    router.startVoiceReply(opened) { started.append($0) }
    #expect(started == ["t1"])
    #expect(router.pending == nil, "an observed-again request resolves to nothing, so no second start")
  }

  @Test("other focuses start nothing")
  func otherFocus() async throws {
    let router = ConversationRouter(log: { _, _ in })
    let opened = try await opened(router, threadID: "t1", focus: .keyboard)
    var started: [String] = []
    router.startVoiceReply(opened) { started.append($0) }
    #expect(started.isEmpty)
  }

  @Test("a voice reply re-reads a memo History holds without its thread yet")
  func staleLocalCopy() async throws {
    let router = ConversationRouter(log: { _, _ in })
    let stale = MemoFactory.memo("m1")
    var fresh = stale
    fresh.threadId = "t1"
    router.open(ConversationLink(memoID: "m1", focus: .voice))
    let pending = try #require(router.pending)
    let result = await router.resolve(pending, isConfigured: true, local: { _ in stale }, fetch: { _ in fresh })
    let opened = try #require(result)
    var started: [String] = []
    router.startVoiceReply(opened) { started.append($0) }
    #expect(started == ["t1"])
  }

  @Test("a voice reply keeps History's copy when the fetch fails")
  func staleLocalCopyFetchFails() async throws {
    let router = ConversationRouter(log: { _, _ in })
    let stale = MemoFactory.memo("m1")
    router.open(ConversationLink(memoID: "m1", focus: .voice))
    let pending = try #require(router.pending)
    let result = await router.resolve(
      pending, isConfigured: true, local: { _ in stale }, fetch: { _ in throw Missing() })
    #expect(result?.memo == stale)
  }

  @Test("a memo that opens as a document leaves no focus behind")
  func documentTakesNoFocus() async throws {
    let router = ConversationRouter(log: { _, _ in })
    let transcript = MemoFactory.memo("m1", mode: .transcribe)
    router.open(ConversationLink(memoID: "m1", focus: .keyboard))
    let pending = try #require(router.pending)
    _ = await router.resolve(pending, isConfigured: true, local: { _ in transcript }, fetch: { _ in transcript })
    #expect(router.takeFocus(forAnyOf: ["m1"]) == .none)
  }

  @Test("a memo without a thread falls back to the keyboard focus")
  func noThread() async throws {
    let router = ConversationRouter(log: { _, _ in })
    let opened = try await opened(router, threadID: nil, focus: .voice)
    var started: [String] = []
    router.startVoiceReply(opened) { started.append($0) }
    #expect(started.isEmpty)
    #expect(router.takeFocus(forAnyOf: ["m1"]) == .keyboard)
  }
}
