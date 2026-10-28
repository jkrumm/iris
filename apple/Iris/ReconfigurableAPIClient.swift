import Foundation
import IrisCore
import Synchronization

/// The `APIClient` every model holds in production: it forwards to the `URLSessionAPIClient` for the saved
/// connection, and swaps it when the connection changes, so no model has to be rebuilt. With no connection it throws
/// `APIError.unauthorized` (no token), which the app avoids by not loading until the connection exists.
nonisolated final class ReconfigurableAPIClient: APIClient {
  private let target = Mutex<(any APIClient)?>(nil)
  private let makeClient: @Sendable (ConnectionCredentials) -> any APIClient

  init(
    credentials: ConnectionCredentials?,
    makeClient: @escaping @Sendable (ConnectionCredentials) -> any APIClient = {
      URLSessionAPIClient(baseURL: $0.serverURL, bearerToken: $0.token)
    }
  ) {
    self.makeClient = makeClient
    reconfigure(credentials)
  }

  func reconfigure(_ credentials: ConnectionCredentials?) {
    let client = credentials.map(makeClient)
    target.withLock { $0 = client }
  }

  private func current() throws -> any APIClient {
    guard let client = target.withLock({ $0 }) else { throw APIError.unauthorized }
    return client
  }

  func health() async throws -> Health { try await current().health() }
  func whoami() async throws -> Whoami { try await current().whoami() }
  func createMemo(_ request: CreateMemoRequest) async throws -> Memo { try await current().createMemo(request) }
  func createTextMemo(_ request: CreateTextMemoRequest) async throws -> Memo {
    try await current().createTextMemo(request)
  }
  func uploadSegment(memoID: String, index: Int, data: Data) async throws {
    try await current().uploadSegment(memoID: memoID, index: index, data: data)
  }
  func completeMemo(id: String, request: CompleteMemoRequest) async throws -> Memo {
    try await current().completeMemo(id: id, request: request)
  }
  func retryMemo(id: String, request: RetryMemoRequest) async throws -> Memo {
    try await current().retryMemo(id: id, request: request)
  }
  func routeMemo(id: String, request: RouteRequest) async throws -> Memo {
    try await current().routeMemo(id: id, request: request)
  }
  func setFlags(id: String, done: Bool?, favorite: Bool?, archived: Bool?) async throws -> Memo {
    try await current().setFlags(id: id, done: done, favorite: favorite, archived: archived)
  }
  func deleteMemo(id: String) async throws -> Memo { try await current().deleteMemo(id: id) }
  func restoreMemo(id: String) async throws -> Memo { try await current().restoreMemo(id: id) }
  func listMemos(_ query: ListMemosQuery) async throws -> MemoPage { try await current().listMemos(query) }
  func memo(id: String) async throws -> MemoDetail { try await current().memo(id: id) }
  func listThreads(_ query: ListThreadsQuery) async throws -> ThreadPage { try await current().listThreads(query) }
  func thread(id: String) async throws -> ThreadDetail { try await current().thread(id: id) }
  func result(id: String, query: MemoResultQuery) async throws -> MemoResult {
    try await current().result(id: id, query: query)
  }
  func registerDevice(_ request: RegisterDeviceRequest) async throws -> RegisterDeviceResponse {
    try await current().registerDevice(request)
  }
  func setActivityToken(memoID: String, request: ActivityTokenRequest) async throws {
    try await current().setActivityToken(memoID: memoID, request: request)
  }
  func herd() async throws -> Herd { try await current().herd() }
  func stats(_ query: StatsQuery) async throws -> Stats { try await current().stats(query) }

  func events() -> AsyncThrowingStream<ServerEvent, any Error> {
    do {
      return try current().events()
    } catch {
      return AsyncThrowingStream { $0.finish(throwing: error) }
    }
  }
}
