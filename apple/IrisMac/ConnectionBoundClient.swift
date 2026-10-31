import Foundation
import IrisCore
import Synchronization

/// Counts connection changes. A request that started under one count and finishes under another belongs to a server the Mac
/// is no longer connected to.
nonisolated final class ConnectionEpoch: Sendable {
  private let count = Mutex(0)

  var current: Int { count.withLock { $0 } }

  func advance() { count.withLock { $0 += 1 } }
}

/// The outbox's client: forwards to `base`, but a create that the old server answers after the connection moved to another
/// server fails as a transport error (a retry, which the new connection then sends) instead of returning a memo. The memo
/// would otherwise be recorded as created and inserted into the new server's History, where it does not exist.
/// Everything else is forwarded as it is.
nonisolated struct ConnectionBoundClient: APIClient {
  let base: any APIClient
  let epoch: ConnectionEpoch

  func createMemo(_ request: CreateMemoRequest) async throws -> Memo {
    let started = epoch.current
    return try stillCurrent(since: started, memo: try await base.createMemo(request))
  }

  func createTextMemo(_ request: CreateTextMemoRequest) async throws -> Memo {
    let started = epoch.current
    return try stillCurrent(since: started, memo: try await base.createTextMemo(request))
  }

  private func stillCurrent(since started: Int, memo: Memo) throws -> Memo {
    guard epoch.current == started else { throw APIError.transport(.cancelled) }
    return memo
  }

  func health() async throws -> Health { try await base.health() }
  func whoami() async throws -> Whoami { try await base.whoami() }
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
  func events() -> AsyncThrowingStream<ServerEvent, any Error> { base.events() }
}
