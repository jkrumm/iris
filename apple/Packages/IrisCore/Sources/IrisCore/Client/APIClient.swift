import Foundation

/// The Iris server's HTTP API (`contracts/manifest.json`). Implementations throw `APIError` (or
/// `CancellationError`) and nothing else.
public protocol APIClient: Sendable {
  /// `GET /health`: the only unauthenticated route.
  func health() async throws -> Health
  /// `GET /v1/whoami`.
  func whoami() async throws -> Whoami
  /// `POST /v1/memos`: idempotent by `request.id`. With `request.threadId` the memo continues that thread (404 when unknown).
  func createMemo(_ request: CreateMemoRequest) async throws -> Memo
  /// `POST /v1/memos/text`: a memo typed instead of spoken. It is created `transcribed` with the text as its
  /// transcript and driven from `route`; there is no upload and no `complete`. Idempotent by `request.id`:
  /// the same body returns the memo, another body for the id throws a 409 `APIError.server`.
  func createTextMemo(_ request: CreateTextMemoRequest) async throws -> Memo
  /// `PUT /v1/memos/:id/segments/:n`: raw m4a bytes, idempotent by content.
  func uploadSegment(memoID: String, index: Int, data: Data) async throws
  /// `POST /v1/memos/:id/complete`. Throws `APIError.missingSegments` while segments are absent.
  func completeMemo(id: String, request: CompleteMemoRequest) async throws -> Memo
  /// `POST /v1/memos/:id/retry`.
  func retryMemo(id: String, request: RetryMemoRequest) async throws -> Memo
  /// `POST /v1/memos/:id/route`: answers a memo parked at `needs_route` (the server routes it and drives
  /// it on) or, after `act`, records a correction and leaves the memo unchanged. Throws a 409
  /// `APIError.server` in any other state, which includes a second answer while the first is still driving.
  func routeMemo(id: String, request: RouteRequest) async throws -> Memo
  /// `PATCH /v1/memos/:id`: sets the flags that are not `nil` (at least one, else a 400 `APIError.server`). A soft-deleted
  /// memo is a 409.
  func setFlags(id: String, done: Bool?, favorite: Bool?, archived: Bool?) async throws -> Memo
  /// `DELETE /v1/memos/:id`: soft delete. The memo comes back with `deletedAt` and `purgeAt`; until then
  /// `restoreMemo(id:)` undoes it. Only a settled memo (`MemoState.isDeletable`) can be deleted, else a 409; repeatable.
  func deleteMemo(id: String) async throws -> Memo
  /// `POST /v1/memos/:id/restore`: the undo of `deleteMemo`. A 409 when the memo is not deleted, a 404 once it is purged.
  func restoreMemo(id: String) async throws -> Memo
  /// `GET /v1/memos`: one page; pass the previous page's `nextCursor` to continue.
  func listMemos(_ query: ListMemosQuery) async throws -> MemoPage
  /// `GET /v1/memos/:id`.
  func memo(id: String) async throws -> MemoDetail
  /// `GET /v1/threads`: one page, newest update first; pass the previous page's `nextCursor` to continue.
  func listThreads(_ query: ListThreadsQuery) async throws -> ThreadPage
  /// `GET /v1/threads/:id`: the thread, its memos and the conversation built from them (no Hermes read).
  /// An unknown thread throws a 404 `APIError.server`.
  func thread(id: String) async throws -> ThreadDetail
  /// `GET /v1/memos/:id/result`: long-polls up to `query.wait` seconds for a result-ready state.
  func result(id: String, query: MemoResultQuery) async throws -> MemoResult
  /// `POST /v1/devices/register`.
  func registerDevice(_ request: RegisterDeviceRequest) async throws -> RegisterDeviceResponse
  /// `PUT /v1/memos/:id/activity-token`.
  func setActivityToken(memoID: String, request: ActivityTokenRequest) async throws
  /// `GET /v1/herd`.
  func herd() async throws -> Herd
  /// `GET /v1/stats`: aggregates over the last `query.days` local days of the server (default 30).
  func stats(_ query: StatsQuery) async throws -> Stats
  /// `GET /v1/events`: opens the SSE stream. It ends when the consumer stops iterating or the connection
  /// drops (the stream then throws); there is no replay, so a consumer refetches the list on reconnect.
  func events() -> AsyncThrowingStream<ServerEvent, any Error>
}
