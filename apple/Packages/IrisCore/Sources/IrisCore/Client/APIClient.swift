import Foundation

/// The Iris server's HTTP API (`contracts/manifest.json`). Implementations throw `APIError` (or
/// `CancellationError`) and nothing else.
public protocol APIClient: Sendable {
  /// `GET /health`: the only unauthenticated route.
  func health() async throws -> Health
  /// `GET /v1/whoami`.
  func whoami() async throws -> Whoami
  /// `POST /v1/memos`: idempotent by `request.id`.
  func createMemo(_ request: CreateMemoRequest) async throws -> Memo
  /// `PUT /v1/memos/:id/segments/:n`: raw m4a bytes, idempotent by content.
  func uploadSegment(memoID: String, index: Int, data: Data) async throws
  /// `POST /v1/memos/:id/complete`. Throws `APIError.missingSegments` while segments are absent.
  func completeMemo(id: String, request: CompleteMemoRequest) async throws -> Memo
  /// `POST /v1/memos/:id/retry`.
  func retryMemo(id: String, request: RetryMemoRequest) async throws -> Memo
  /// `GET /v1/memos`: one page; pass the previous page's `nextCursor` to continue.
  func listMemos(_ query: ListMemosQuery) async throws -> MemoPage
  /// `GET /v1/memos/:id`.
  func memo(id: String) async throws -> MemoDetail
  /// `GET /v1/memos/:id/result`: long-polls up to `query.wait` seconds for a result-ready state.
  func result(id: String, query: MemoResultQuery) async throws -> MemoResult
  /// `POST /v1/devices/register`.
  func registerDevice(_ request: RegisterDeviceRequest) async throws -> RegisterDeviceResponse
  /// `PUT /v1/memos/:id/activity-token`.
  func setActivityToken(memoID: String, request: ActivityTokenRequest) async throws
  /// `GET /v1/herd`.
  func herd() async throws -> Herd
  /// `GET /v1/events`: opens the SSE stream. It ends when the consumer stops iterating or the connection
  /// drops (the stream then throws); there is no replay, so a consumer refetches the list on reconnect.
  func events() -> AsyncThrowingStream<ServerEvent, any Error>
}
