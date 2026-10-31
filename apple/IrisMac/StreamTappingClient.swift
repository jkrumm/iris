import Foundation
import IrisCore

/// An `APIClient` that forwards to `base` and tells `ready` each time the event stream says `ready`: the stream connected,
/// at launch and after every drop. A list request that succeeds while the stream is down is not that, so only this signal
/// says the server is back with its stream (the open detail reloads on it). Every `memo.updated` / `memo.done` payload (id and
/// state) is handed to `states` in stream order, for the notifier's transitions.
nonisolated struct StreamTappingClient: APIClient {
  let base: any APIClient
  let ready: AsyncStream<Void>.Continuation
  var states: AsyncStream<MemoEvent>.Continuation?

  func health() async throws -> Health { try await base.health() }
  func whoami() async throws -> Whoami { try await base.whoami() }
  func createMemo(_ request: CreateMemoRequest) async throws -> Memo { try await base.createMemo(request) }
  func createTextMemo(_ request: CreateTextMemoRequest) async throws -> Memo { try await base.createTextMemo(request) }
  func uploadSegment(memoID: String, index: Int, data: Data) async throws {
    try await base.uploadSegment(memoID: memoID, index: index, data: data)
  }
  func completeMemo(id: String, request: CompleteMemoRequest) async throws -> Memo {
    try await base.completeMemo(id: id, request: request)
  }
  func retryMemo(id: String, request: RetryMemoRequest) async throws -> Memo {
    try await base.retryMemo(id: id, request: request)
  }
  func routeMemo(id: String, request: RouteRequest) async throws -> Memo {
    try await base.routeMemo(id: id, request: request)
  }
  func setFlags(id: String, done: Bool?, favorite: Bool?, archived: Bool?) async throws -> Memo {
    try await base.setFlags(id: id, done: done, favorite: favorite, archived: archived)
  }
  func deleteMemo(id: String) async throws -> Memo { try await base.deleteMemo(id: id) }
  func restoreMemo(id: String) async throws -> Memo { try await base.restoreMemo(id: id) }
  func listMemos(_ query: ListMemosQuery) async throws -> MemoPage { try await base.listMemos(query) }
  func memo(id: String) async throws -> MemoDetail { try await base.memo(id: id) }
  func listThreads(_ query: ListThreadsQuery) async throws -> ThreadPage { try await base.listThreads(query) }
  func thread(id: String) async throws -> ThreadDetail { try await base.thread(id: id) }
  func result(id: String, query: MemoResultQuery) async throws -> MemoResult {
    try await base.result(id: id, query: query)
  }
  func registerDevice(_ request: RegisterDeviceRequest) async throws -> RegisterDeviceResponse {
    try await base.registerDevice(request)
  }
  func setActivityToken(memoID: String, request: ActivityTokenRequest) async throws {
    try await base.setActivityToken(memoID: memoID, request: request)
  }
  func herd() async throws -> Herd { try await base.herd() }
  func stats(_ query: StatsQuery) async throws -> Stats { try await base.stats(query) }

  func events() -> AsyncThrowingStream<ServerEvent, any Error> {
    let upstream = base.events()
    let ready = ready
    let states = states
    return AsyncThrowingStream { continuation in
      let forwarding = Task {
        do {
          for try await event in upstream {
            switch event {
            case .ready: ready.yield()
            case .memoUpdated(let update), .memoDone(let update): states?.yield(update)
            }
            continuation.yield(event)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in forwarding.cancel() }
    }
  }
}
