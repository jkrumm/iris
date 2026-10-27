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
