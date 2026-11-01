import Foundation
import IrisCore
import IrisUI
import Synchronization
import Testing

@testable import Iris

/// History → `LastMemoWidgetFeed` → the App Group snapshot, through the same `attach(to:)` the composition root calls.
@MainActor
@Suite("Last-memo widget wiring")
struct LastMemoWidgetWiringTests {
  private final class Server: Sendable {
    private let key: Mutex<String?>
    init(_ key: String?) { self.key = Mutex(key) }
    var current: String? { key.withLock { $0 } }
    func switchTo(_ key: String?) { self.key.withLock { $0 = key } }
  }

  private final class Reloads {
    var count = 0
  }

  let client = FakeAPIClient(now: { MemoFactory.now })
  let store = InMemoryLastMemoSnapshotStore()
  private let reloads = Reloads()
  private let server = Server("server-a")
  let history: HistoryModel

  init() {
    history = HistoryModel(client: client, serverKey: { [server] in server.current })
    let reloads = reloads
    LastMemoWidgetFeed(store: store, reload: { reloads.count += 1 }, now: { MemoFactory.now }).attach(to: history)
  }

  private func update(_ id: String, _ state: MemoState = .received) async {
    await history.handle(.memoUpdated(MemoEvent(id: id, state: state, at: MemoFactory.now)))
  }

  @Test("a memo update reaches the feed, and the finished state replaces the running one")
  func updateReachesTheFeed() async {
    await client.seed(MemoFactory.detail(MemoFactory.memo("m", state: .transcribed)))
    await update("m", .transcribed)
    #expect(store.load()?.phase == .processing)
    #expect(store.load()?.routeChip == nil, "an unrouted memo has no chip; its mode is not a route")

    let summary = MemoSummary(headline: "Wochenplan abgestimmt", detail: "Details", spoken: "Gesprochen")
    await client.seed(
      MemoFactory.detail(
        MemoFactory.memo("m", state: .notified, route: "hermes", transcript: "geheimer Text", summary: summary)))
    await update("m", .notified)
    #expect(store.load()?.phase == .done)
    #expect(store.load()?.routeChip == "Hermes")
    #expect(store.load()?.headline == "Wochenplan abgestimmt")
    #expect(reloads.count == 2)
  }

  @Test("the snapshot never carries the transcript, the reply or the error")
  func neverTheTranscript() async throws {
    await client.seed(
      MemoFactory.detail(
        MemoFactory.memo(
          "f", state: .failed, failedStep: .act, error: "geheimer Fehler", transcript: "geheimer Text",
          replyText: "geheime Antwort")))
    await update("f", .failed)
    let snapshot = try #require(store.load())
    #expect(snapshot.phase == .failed)
    #expect(snapshot.headline == nil)
    let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    #expect(!json.contains("geheim"))
  }

  @Test("a parked memo is needsRoute until the user marks it done")
  func parked() async {
    await client.seed(MemoFactory.detail(MemoFactory.memo("p", state: .needsRoute)))
    await update("p", .needsRoute)
    #expect(store.load()?.phase == .needsRoute)
    await client.seed(MemoFactory.detail(MemoFactory.memo("p", state: .needsRoute, done: true)))
    await update("p", .needsRoute)
    #expect(store.load()?.phase == .done)
  }

  @Test("a refresh asked of the old server that answers after a connection switch does not feed the widget")
  func switchDoesNotFeedTheOldServersMemo() async {
    await client.seed(MemoFactory.detail(MemoFactory.memo("on-a", state: .notified)))
    let gate = await client.hold(.memo)

    let handling = Task { await update("on-a", .notified) }
    await gate.waitUntilHeld()
    server.switchTo("server-b")
    gate.release()
    await handling.value

    #expect(store.load() == nil)
    #expect(reloads.count == 0)
  }

  @Test("the first page of the server History reads feeds its newest memo; a filtered page does not")
  func firstPageFeedsTheNewest() async {
    await client.seed(MemoFactory.detail(MemoFactory.memo("old", age: 500, state: .notified, favorite: true)))
    await client.seed(MemoFactory.detail(MemoFactory.memo("new", age: 5, state: .acted)))
    history.filters.toggle(.favorites)
    await history.load()
    #expect(store.load() == nil, "a filtered page is not the newest memo")

    history.filters.clear()
    await history.load()
    #expect(store.load()?.memoID == "new")
  }

  @Test("a memo the user discards, or the server no longer has, leaves the widget")
  func forgotten() async {
    await client.seed(MemoFactory.detail(MemoFactory.memo("a", state: .acted)))
    await update("a", .acted)
    #expect(store.load()?.memoID == "a")
    history.hide("a")
    #expect(store.load() == nil)
    await update("a", .notified)
    #expect(store.load() == nil, "a late event does not bring a hidden memo back")
  }

  @Test("a create hand-off from the old server is not fed after a switch")
  func staleHandOff() {
    server.switchTo("server-b")
    history.insert(MemoFactory.memo("from-a"), origin: "server-a")
    #expect(store.load() == nil)
    history.insert(MemoFactory.memo("from-b", state: .received), origin: "server-b")
    #expect(store.load()?.memoID == "from-b")
  }
}
