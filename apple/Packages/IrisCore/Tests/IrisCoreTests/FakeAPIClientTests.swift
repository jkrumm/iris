import Foundation
import Testing

@testable import IrisCore

@Suite("FakeAPIClient")
struct FakeAPIClientTests {
  private let started = Date(timeIntervalSince1970: 1_773_480_000)

  private func create(_ fake: FakeAPIClient, id: String = "m1") async throws -> Memo {
    try await fake.createMemo(CreateMemoRequest(id: id, mode: .auto, startedAt: started))
  }

  @Test("createMemo is idempotent and the call log records everything")
  func createIsIdempotent() async throws {
    let fake = FakeAPIClient(deviceID: "iphone", now: { Date(timeIntervalSince1970: 1_773_480_001) })
    let first = try await create(fake)
    let second = try await create(fake)

    #expect(first == second)
    #expect(first.state == .receiving)
    #expect(first.device == "iphone")
    #expect(await fake.calls.count == 2)
  }

  @Test("createTextMemo creates a transcribed typed memo, idempotent for the same body, 409 for another")
  func textMemo() async throws {
    let fake = FakeAPIClient()
    let request = CreateTextMemoRequest(id: "t1", mode: .hermes, startedAt: started, text: "  kauf Milch \n")
    let memo = try await fake.createTextMemo(request)
    #expect(memo.state == .transcribed)
    #expect(memo.transcript == "kauf Milch")
    #expect(memo.isTyped)
    #expect(try await fake.createTextMemo(request) == memo)
    #expect(await fake.calls.last == .createTextMemo(request))

    var other = request
    other.text = "etwas anderes"
    await #expect(throws: APIError.self) { try await fake.createTextMemo(other) }
  }

  @Test("createTextMemo counts Unicode code points, not Characters")
  func textMemoCodePoints() async throws {
    let fake = FakeAPIClient()
    // A family emoji is one Character but five code points.
    let family = "👨‍👩‍👧"
    let fits = String(repeating: family, count: CreateTextMemoRequest.maxTextCharacters / 5)
    _ = try await fake.createTextMemo(CreateTextMemoRequest(id: "t3", mode: .auto, startedAt: started, text: fits))
    await #expect(throws: APIError.self) {
      try await fake.createTextMemo(
        CreateTextMemoRequest(id: "t4", mode: .auto, startedAt: started, text: fits + family))
    }
  }

  @Test("createTextMemo rejects empty and oversized text with a 400")
  func textMemoValidation() async throws {
    let fake = FakeAPIClient()
    for text in ["", "  \n ", String(repeating: "x", count: CreateTextMemoRequest.maxTextCharacters + 1)] {
      await #expect(throws: APIError.self) {
        try await fake.createTextMemo(CreateTextMemoRequest(id: "t2", mode: .auto, startedAt: started, text: text))
      }
    }
  }

  private func seededThread(_ fake: FakeAPIClient, id: String = "t1", kind: ThreadKind = .chat) async -> MemoThread {
    let thread = MemoThread(id: id, kind: kind, title: "earlier", createdAt: started, updatedAt: started)
    await fake.seed(ThreadDetail(thread: thread, memos: [], messages: []))
    return thread
  }

  @Test("A memo that continues a thread files itself there and moves the thread; an unknown thread is a 404")
  func continuesThread() async throws {
    let fake = FakeAPIClient(now: { Date(timeIntervalSince1970: 1_773_480_100) })
    await #expect(throws: APIError.self) {
      try await fake.createTextMemo(
        CreateTextMemoRequest(id: "m1", mode: .chat, startedAt: started, text: "hi", threadId: "nope"))
    }
    #expect(await fake.memos["m1"] == nil)

    _ = await seededThread(fake)
    let memo = try await fake.createTextMemo(
      CreateTextMemoRequest(id: "m1", mode: .chat, startedAt: started, text: "hi", threadId: "t1"))
    #expect(memo.threadId == "t1")
    let detail = try await fake.thread(id: "t1")
    #expect(detail.memos.map(\.id) == ["m1"])
    #expect(detail.messages.map(\.memoId) == ["m1"])
    #expect(detail.messages.map(\.content) == ["hi"])
    #expect(detail.thread.lastMemoId == "m1")
    #expect(detail.thread.updatedAt == Date(timeIntervalSince1970: 1_773_480_100))

    let recorded = try await fake.createMemo(
      CreateMemoRequest(id: "m2", mode: .chat, startedAt: started, threadId: "t1"))
    #expect(recorded.threadId == "t1")
    #expect(try await fake.thread(id: "t1").memos.map(\.id) == ["m1", "m2"])
  }

  @Test("A replay with another thread is a 409")
  func replayWithAnotherThread() async throws {
    let fake = FakeAPIClient()
    _ = await seededThread(fake)
    _ = await seededThread(fake, id: "t2")
    let request = CreateMemoRequest(id: "m1", mode: .chat, startedAt: started, threadId: "t1")
    let first = try await fake.createMemo(request)
    #expect(try await fake.createMemo(request) == first)

    var other = request
    other.threadId = "t2"
    await #expect(throws: APIError.self) { try await fake.createMemo(other) }
    other.threadId = nil
    await #expect(throws: APIError.self) { try await fake.createMemo(other) }
  }

  @Test("listThreads pages newest update first and filters by kind; an unknown thread is a 404")
  func threadList() async throws {
    let fake = FakeAPIClient()
    for (index, kind) in [ThreadKind.chat, .hermes, .chat].enumerated() {
      var thread = await seededThread(fake, id: "t\(index)", kind: kind)
      thread.updatedAt = Date(timeIntervalSince1970: 1_773_480_000 + Double(index))
      await fake.seed(ThreadDetail(thread: thread, memos: [], messages: []))
    }
    let first = try await fake.listThreads(ListThreadsQuery(limit: 2))
    #expect(first.items.map(\.id) == ["t2", "t1"])
    let second = try await fake.listThreads(ListThreadsQuery(limit: 2, cursor: first.nextCursor))
    #expect(second.items.map(\.id) == ["t0"])
    #expect(second.nextCursor == nil)
    #expect(try await fake.listThreads(ListThreadsQuery(kind: .chat)).items.map(\.id) == ["t2", "t0"])
    await #expect(throws: APIError.self) { try await fake.thread(id: "nope") }
    #expect(await fake.calls.last == .thread(id: "nope"))
  }

  @Test("complete reports missing segments, then succeeds once they are uploaded")
  func completeFlow() async throws {
    let fake = FakeAPIClient()
    _ = try await create(fake)
    try await fake.uploadSegment(memoID: "m1", index: 0, data: Data([1]))
    try await fake.uploadSegment(memoID: "m1", index: 2, data: Data([3]))

    await #expect(throws: APIError.missingSegments(message: "segments missing: 1", missing: [1])) {
      try await fake.completeMemo(id: "m1", request: CompleteMemoRequest(segmentCount: 3))
    }

    try await fake.uploadSegment(memoID: "m1", index: 1, data: Data([2]))
    let memo = try await fake.completeMemo(id: "m1", request: CompleteMemoRequest(segmentCount: 3))
    #expect(memo.state == .received)
    #expect(memo.segmentCount == 3)
    #expect(await fake.calls.last == .completeMemo(id: "m1", request: CompleteMemoRequest(segmentCount: 3)))
  }

  @Test("Scripted failures are consumed one per call")
  func scriptedFailures() async throws {
    let fake = FakeAPIClient()
    await fake.enqueueFailure(.transport(.timedOut), for: .createMemo)
    await fake.enqueueFailure(.unauthorized, for: .createMemo)

    await #expect(throws: APIError.transport(.timedOut)) { try await create(fake) }
    await #expect(throws: APIError.unauthorized) { try await create(fake) }
    #expect(try await create(fake).id == "m1")
  }

  @Test("Unknown memos answer 404")
  func notFound() async {
    let fake = FakeAPIClient()
    await #expect(throws: APIError.server(status: 404, body: ErrorBody(error: .notFound, message: "memo not found"))) {
      try await fake.memo(id: "nope")
    }
  }

  @Test("result answers from the memo state unless results are scripted")
  func results() async throws {
    let fake = FakeAPIClient()
    let memo = try await create(fake)
    var done = memo
    done.state = .notified

    guard case .pending = try await fake.result(id: "m1", query: MemoResultQuery(wait: 1)) else {
      Issue.record("a receiving memo is pending")
      return
    }
    await fake.enqueueResults([.ready(done)], for: "m1")
    #expect(try await fake.result(id: "m1", query: MemoResultQuery()) == .ready(done))
  }

  private func parked(_ fake: FakeAPIClient) async throws -> Memo {
    var memo = try await create(fake)
    memo.state = .needsRoute
    memo.routeReason = "journal not available"
    await fake.seed(MemoDetail(memo: memo, steps: []))
    return memo
  }

  @Test("routeMemo routes a parked memo and clears the park details")
  func routeAnswer() async throws {
    let fake = FakeAPIClient()
    _ = try await parked(fake)
    let routed = try await fake.routeMemo(id: "m1", request: RouteRequest(destination: .hermes))
    #expect(routed.state == .routed)
    #expect(routed.route == "hermes")
    #expect(routed.routeReason == nil)
    #expect(await fake.calls.last == .routeMemo(id: "m1", request: RouteRequest(destination: .hermes)))
  }

  @Test("routeMemo after act leaves the memo as it is; other states and a second answer are 409")
  func routeCorrectionAndConflict() async throws {
    let fake = FakeAPIClient()
    var memo = try await create(fake)
    memo.state = .notified
    await fake.seed(MemoDetail(memo: memo, steps: []))
    #expect(try await fake.routeMemo(id: "m1", request: RouteRequest(destination: .hermes)) == memo)

    memo.state = .transcribed
    await fake.seed(MemoDetail(memo: memo, steps: []))
    await #expect(
      throws: APIError.server(
        status: 409, body: ErrorBody(error: .badState, message: "only parked or acted memos take a route"))
    ) {
      try await fake.routeMemo(id: "m1", request: RouteRequest(destination: .hermes))
    }
  }

  @Test("stats answers the scripted value, records the query and can be scripted to fail")
  func stats() async throws {
    let fake = FakeAPIClient()
    let scripted = Stats(days: 7, from: "2026-03-08", to: "2026-03-14")
    await fake.setStats(scripted)
    #expect(try await fake.stats(StatsQuery(days: 7)) == scripted)
    #expect(await fake.calls.last == .stats(StatsQuery(days: 7)))

    await fake.enqueueFailure(.unexpectedStatus(500), for: .stats)
    await #expect(throws: APIError.unexpectedStatus(500)) { try await fake.stats(StatsQuery()) }
  }

  @Test("routeMemo wants a tab for herdr and only for herdr")
  func routeTabRule() async throws {
    let fake = FakeAPIClient()
    _ = try await parked(fake)
    for request in [RouteRequest(destination: .herdr), RouteRequest(destination: .hermes, tab: "w1:t1")] {
      await #expect(throws: APIError.self) { try await fake.routeMemo(id: "m1", request: request) }
    }
    #expect(
      try await fake.routeMemo(id: "m1", request: RouteRequest(destination: .herdr, tab: "w1:t1")).route == "herdr")
  }

  @Test("list pages newest first with a cursor")
  func listing() async throws {
    let fake = FakeAPIClient(now: { Date(timeIntervalSince1970: 1_773_480_100) })
    for id in ["a", "b", "c"] { _ = try await create(fake, id: id) }

    let first = try await fake.listMemos(ListMemosQuery(limit: 2))
    #expect(first.items.count == 2)
    #expect(first.nextCursor == "2")
    let second = try await fake.listMemos(ListMemosQuery(limit: 2, cursor: first.nextCursor))
    #expect(second.items.count == 1)
    #expect(second.nextCursor == nil)
  }

  @Test("list searches, filters and pins needs_route memos on the first page")
  func searchingAndPinning() async throws {
    let fake = FakeAPIClient(now: { Date(timeIntervalSince1970: 1_773_480_100) })
    for id in ["a", "b"] { _ = try await create(fake, id: id) }
    let parkedMemo = try await parked(fake)

    let first = try await fake.listMemos(ListMemosQuery())
    #expect(first.pinned.map(\.id) == [parkedMemo.id])
    #expect(first.items.map(\.id).sorted() == ["a", "b"])
    let later = try await fake.listMemos(ListMemosQuery(limit: 1, cursor: "1"))
    #expect(later.pinned.isEmpty)

    let onlyParked = try await fake.listMemos(ListMemosQuery(state: .needsRoute))
    #expect(onlyParked.items.isEmpty)
    #expect(onlyParked.pinned.count == 1)
    #expect(try await fake.listMemos(ListMemosQuery(q: "nichts-davon")).items.isEmpty)
    #expect(try await fake.listMemos(ListMemosQuery(route: .journal)).items.isEmpty)
  }

  @Test("emit feeds the events stream")
  func eventStream() async throws {
    let fake = FakeAPIClient()
    fake.emit(.ready)
    fake.finishEvents()
    var received: [ServerEvent] = []
    for try await event in fake.events() { received.append(event) }
    #expect(received == [.ready])
  }

  // MARK: Flags, delete and restore

  private func seedMemo(
    _ fake: FakeAPIClient, id: String, state: MemoState = .notified, createdAt: TimeInterval = 1_773_480_000,
    threadId: String? = nil
  ) async {
    let date = Date(timeIntervalSince1970: createdAt)
    let memo = Memo(
      id: id, mode: .auto, device: "fake-device", startedAt: date, state: state, threadId: threadId, createdAt: date,
      updatedAt: date)
    await fake.seed(MemoDetail(memo: memo, steps: []))
  }

  private func listedIDs(_ fake: FakeAPIClient, _ query: ListMemosQuery = ListMemosQuery()) async throws -> (
    items: [String], pinned: [String]
  ) {
    let page = try await fake.listMemos(query)
    return (page.items.map(\.id), page.pinned.map(\.id))
  }

  @Test("setFlags sets only the given flags, and 400s for none")
  func setFlags() async throws {
    let fake = FakeAPIClient()
    await seedMemo(fake, id: "m1")
    let memo = try await fake.setFlags(id: "m1", done: true, favorite: nil, archived: nil)
    #expect(memo.done && !memo.favorite && !memo.archived)
    let both = try await fake.setFlags(id: "m1", done: nil, favorite: true, archived: true)
    #expect(both.done && both.favorite && both.archived)
    #expect(await fake.calls.last == .setFlags(id: "m1", done: nil, favorite: true, archived: true))

    await #expect(throws: APIError.self) { try await fake.setFlags(id: "m1", done: nil, favorite: nil, archived: nil) }
    await #expect(throws: APIError.self) {
      try await fake.setFlags(id: "nope", done: true, favorite: nil, archived: nil)
    }
  }

  @Test("deleteMemo soft-deletes a settled memo, is repeatable, and refuses one that is still running")
  func deleteMemo() async throws {
    let fake = FakeAPIClient(now: { Date(timeIntervalSince1970: 1_773_480_100) })
    await seedMemo(fake, id: "m1")
    await seedMemo(fake, id: "running", state: .routed)
    let deleted = try await fake.deleteMemo(id: "m1")
    #expect(deleted.deletedAt == Date(timeIntervalSince1970: 1_773_480_100))
    #expect(deleted.purgeAt == deleted.deletedAt?.addingTimeInterval(FakeAPIClient.purgeWindow))
    #expect(try await fake.deleteMemo(id: "m1") == deleted)

    await #expect(throws: APIError.self) { try await fake.deleteMemo(id: "running") }
    await #expect(throws: APIError.self) { try await fake.setFlags(id: "m1", done: true, favorite: nil, archived: nil) }
    #expect(try await fake.memo(id: "m1").memo.isDeleted)
  }

  @Test("restoreMemo undoes a delete, 409s when not deleted and 404s once the purge window is over")
  func restoreMemo() async throws {
    let clock = LockedDate(Date(timeIntervalSince1970: 1_773_480_100))
    let fake = FakeAPIClient(now: { clock.value })
    await seedMemo(fake, id: "m1")
    await #expect(throws: APIError.self) { try await fake.restoreMemo(id: "m1") }

    _ = try await fake.deleteMemo(id: "m1")
    let restored = try await fake.restoreMemo(id: "m1")
    #expect(!restored.isDeleted && restored.purgeAt == nil)

    _ = try await fake.deleteMemo(id: "m1")
    clock.advance(FakeAPIClient.purgeWindow)
    await #expect(throws: APIError.self) { try await fake.restoreMemo(id: "m1") }
    await #expect(throws: APIError.self) { try await fake.memo(id: "m1") }
    #expect(await fake.memos["m1"] == nil)
  }

  @Test("listMemos hides deleted and archived memos and filters favorites, archived and kind")
  func listFilters() async throws {
    let fake = FakeAPIClient()
    for (index, id) in ["plain", "star", "archived", "gone", "chat"].enumerated() {
      await seedMemo(
        fake, id: id, createdAt: 1_773_480_000 + Double(index), threadId: id == "chat" ? "t1" : nil)
    }
    await fake.seed(
      ThreadDetail(
        thread: MemoThread(id: "t1", kind: .chat, title: "t", createdAt: Date(), updatedAt: Date()), memos: [],
        messages: []))
    _ = try await fake.setFlags(id: "star", done: nil, favorite: true, archived: nil)
    _ = try await fake.setFlags(id: "archived", done: nil, favorite: nil, archived: true)
    _ = try await fake.deleteMemo(id: "gone")

    #expect(try await listedIDs(fake).items == ["chat", "star", "plain"])
    #expect(try await listedIDs(fake, ListMemosQuery(favorite: true)).items == ["star"])
    #expect(try await listedIDs(fake, ListMemosQuery(archived: true)).items == ["archived"])
    #expect(try await listedIDs(fake, ListMemosQuery(kind: .chat)).items == ["chat"])
    #expect(try await listedIDs(fake, ListMemosQuery(kind: .hermes)).items.isEmpty)
  }

  @Test("A done needs_route memo is not pinned and is paged instead; a deleted one is in neither")
  func pinnedSkipsDone() async throws {
    let fake = FakeAPIClient()
    await seedMemo(fake, id: "open", state: .needsRoute, createdAt: 1_773_480_002)
    await seedMemo(fake, id: "handled", state: .needsRoute, createdAt: 1_773_480_001)
    await seedMemo(fake, id: "dropped", state: .needsRoute, createdAt: 1_773_480_000)
    _ = try await fake.setFlags(id: "handled", done: true, favorite: nil, archived: nil)
    #expect(try await listedIDs(fake).pinned == ["open", "dropped"])
    #expect(try await listedIDs(fake).items == ["handled"])

    _ = try await fake.deleteMemo(id: "dropped")
    let page = try await listedIDs(fake)
    #expect(page.pinned == ["open"] && page.items == ["handled"])
  }

  @Test("a held response applies its effect at once and answers only after the gate opens")
  func heldResponse() async throws {
    let fake = FakeAPIClient()
    _ = try await create(fake)
    _ = try await fake.completeMemo(id: "m1", request: CompleteMemoRequest(segmentCount: 0))
    let gate = await fake.hold(.setFlags)

    let flagged = Task { try await fake.setFlags(id: "m1", done: nil, favorite: true, archived: nil) }
    await gate.waitUntilHeld()
    // The server state moved while the answer is still on its way.
    #expect(try await fake.memo(id: "m1").memo.favorite)

    gate.release()
    #expect(try await flagged.value.favorite)
  }

  @Test("a held failure is thrown only after release, and a gate released early does not block")
  func heldFailureAndEarlyRelease() async throws {
    let fake = FakeAPIClient()
    await fake.enqueueFailure(.unexpectedStatus(500), for: .stats)
    let failing = await fake.hold(.stats)
    let failed = Task { try await fake.stats(StatsQuery()) }
    await failing.waitUntilHeld()
    failing.release()
    await #expect(throws: APIError.self) { try await failed.value }

    let early = await fake.hold(.stats)
    early.release()
    #expect(try await fake.stats(StatsQuery()).days == 30)
  }
}

/// A clock a test moves, readable from the fake's `@Sendable` closure.
private final class LockedDate: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) { self.date = date }

  var value: Date { lock.withLock { date } }

  func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

@Suite("FakeAPIClient pipeline")
struct FakeAPIClientPipelineTests {
  private let started = Date(timeIntervalSince1970: 1_773_480_000)

  @Test("advance moves a memo and its thread through the pipeline and emits the events")
  func advanceFollowsThePipeline() async throws {
    let fake = FakeAPIClient()
    await fake.seed(
      ThreadDetail(
        thread: MemoThread(id: "t1", kind: .hermes, title: "Thread", createdAt: started, updatedAt: started),
        memos: [], messages: []))
    _ = try await fake.createMemo(CreateMemoRequest(id: "m1", mode: .hermes, startedAt: started, threadId: "t1"))
    var events = fake.events().makeAsyncIterator()

    try await fake.advance("m1", to: .transcribed, transcript: "hello there")
    try await fake.advance("m1", to: .notified, replyText: "hi")

    let memo = try await fake.memo(id: "m1").memo
    #expect(memo.state == .notified)
    #expect(memo.transcript == "hello there")
    #expect(memo.replyText == "hi")
    let thread = try await fake.thread(id: "t1")
    #expect(thread.messages.map(\.role) == [.user, .assistant])
    #expect(thread.messages.map(\.content) == ["hello there", "hi"])
    #expect(thread.memos.first?.state == .notified)

    var names: [String] = []
    while let event = try await events.next() {
      switch event {
      case .memoUpdated(let update): names.append("updated:\(update.state.rawValue)")
      case .memoDone(let update):
        names.append("done:\(update.state.rawValue)")
      case .ready: continue
      }
      if names.last == "done:notified" { break }
    }
    #expect(names == ["updated:transcribed", "updated:notified", "done:notified"])
  }

  @Test("advance on an unknown memo is a 404")
  func advanceUnknown() async {
    let fake = FakeAPIClient()
    await #expect(throws: APIError.self) { try await fake.advance("nope", to: .notified) }
  }
}
