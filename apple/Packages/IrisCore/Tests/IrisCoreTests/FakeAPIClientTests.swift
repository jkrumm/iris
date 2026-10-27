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

  @Test("createTextMemo rejects empty and oversized text with a 400")
  func textMemoValidation() async throws {
    let fake = FakeAPIClient()
    for text in ["", "  \n ", String(repeating: "x", count: CreateTextMemoRequest.maxTextCharacters + 1)] {
      await #expect(throws: APIError.self) {
        try await fake.createTextMemo(CreateTextMemoRequest(id: "t2", mode: .auto, startedAt: started, text: text))
      }
    }
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

  @Test("emit feeds the events stream")
  func eventStream() async throws {
    let fake = FakeAPIClient()
    fake.emit(.ready)
    fake.finishEvents()
    var received: [ServerEvent] = []
    for try await event in fake.events() { received.append(event) }
    #expect(received == [.ready])
  }
}
