import Foundation

/// An in-memory `APIClient` for tests and previews in any package. It behaves like a small server:
/// memos are stored, segments are tracked, `complete` reports missing segments, `result` answers from
/// the stored state. It records every call and lets a test script failures and results.
public actor FakeAPIClient: APIClient {
  /// A call as the client saw it. Segment bytes are reduced to their count.
  public enum Call: Hashable, Sendable {
    case health
    case whoami
    case createMemo(CreateMemoRequest)
    case uploadSegment(memoID: String, index: Int, byteCount: Int)
    case completeMemo(id: String, request: CompleteMemoRequest)
    case retryMemo(id: String, request: RetryMemoRequest)
    case routeMemo(id: String, request: RouteRequest)
    case listMemos(ListMemosQuery)
    case memo(id: String)
    case result(id: String, query: MemoResultQuery)
    case registerDevice(RegisterDeviceRequest)
    case setActivityToken(memoID: String, request: ActivityTokenRequest)
    case herd
  }

  /// The endpoints a failure can be scripted for.
  public enum Endpoint: Hashable, Sendable {
    case health, whoami, createMemo, uploadSegment, completeMemo, retryMemo, routeMemo, listMemos, memo, result
    case registerDevice, setActivityToken, herd
  }

  public private(set) var calls: [Call] = []
  public private(set) var memos: [String: MemoDetail] = [:]
  public private(set) var segments: [String: [Int: Data]] = [:]
  public private(set) var activityTokens: [String: String] = [:]
  public var deviceID: String
  public var healthResponse = Health(status: .ok, degraded: [], inflight: 0)
  public var herdResponse = Herd(tabs: [])

  private let now: @Sendable () -> Date
  private var failures: [Endpoint: [APIError]] = [:]
  private var scriptedResults: [String: [MemoResult]] = [:]
  private let eventStream: AsyncThrowingStream<ServerEvent, any Error>
  private let eventContinuation: AsyncThrowingStream<ServerEvent, any Error>.Continuation

  public init(deviceID: String = "fake-device", now: @escaping @Sendable () -> Date = { Date() }) {
    self.deviceID = deviceID
    self.now = now
    (eventStream, eventContinuation) = AsyncThrowingStream<ServerEvent, any Error>.makeStream()
  }

  // MARK: Scripting

  /// Makes the next call to `endpoint` throw `error`. Queued errors are consumed one per call, in order.
  public func enqueueFailure(_ error: APIError, for endpoint: Endpoint) {
    failures[endpoint, default: []].append(error)
  }

  /// Queues the answers `result(id:)` gives before it falls back to the stored memo's state.
  public func enqueueResults(_ results: [MemoResult], for memoID: String) {
    scriptedResults[memoID, default: []].append(contentsOf: results)
  }

  /// Stores a memo as if the server already had it.
  public func seed(_ detail: MemoDetail) {
    memos[detail.id] = detail
  }

  public func setHealth(_ health: Health) { healthResponse = health }

  public func setHerd(_ herd: Herd) { herdResponse = herd }

  /// Pushes an event to the consumer of `events()`. The stream has a single consumer.
  public nonisolated func emit(_ event: ServerEvent) {
    eventContinuation.yield(event)
  }

  /// Ends the `events()` stream, with an error when given.
  public nonisolated func finishEvents(throwing error: (any Error)? = nil) {
    eventContinuation.finish(throwing: error)
  }

  // MARK: APIClient

  public func health() async throws -> Health {
    calls.append(.health)
    try failIfScripted(.health)
    return healthResponse
  }

  public func whoami() async throws -> Whoami {
    calls.append(.whoami)
    try failIfScripted(.whoami)
    return Whoami(device: deviceID)
  }

  public func createMemo(_ request: CreateMemoRequest) async throws -> Memo {
    calls.append(.createMemo(request))
    try failIfScripted(.createMemo)
    if let existing = memos[request.id] { return existing.memo }
    let timestamp = now()
    let memo = Memo(
      id: request.id, mode: request.mode, device: deviceID, startedAt: request.startedAt, state: .receiving,
      createdAt: timestamp, updatedAt: timestamp)
    memos[request.id] = MemoDetail(memo: memo, steps: [])
    return memo
  }

  public func uploadSegment(memoID: String, index: Int, data: Data) async throws {
    calls.append(.uploadSegment(memoID: memoID, index: index, byteCount: data.count))
    try failIfScripted(.uploadSegment)
    guard memos[memoID] != nil else { throw notFound("memo not found") }
    segments[memoID, default: [:]][index] = data
  }

  public func completeMemo(id: String, request: CompleteMemoRequest) async throws -> Memo {
    calls.append(.completeMemo(id: id, request: request))
    try failIfScripted(.completeMemo)
    guard var detail = memos[id] else { throw notFound("memo not found") }
    let received = Set(segments[id, default: [:]].keys)
    let missing = (0..<request.segmentCount).filter { !received.contains($0) }
    guard missing.isEmpty else {
      throw APIError.missingSegments(
        message: "segments missing: \(missing.map(String.init).joined(separator: ", "))", missing: missing)
    }
    detail.memo.state = .received
    detail.memo.segmentCount = request.segmentCount
    detail.memo.updatedAt = now()
    memos[id] = detail
    return detail.memo
  }

  public func retryMemo(id: String, request: RetryMemoRequest) async throws -> Memo {
    calls.append(.retryMemo(id: id, request: request))
    try failIfScripted(.retryMemo)
    guard var detail = memos[id] else { throw notFound("memo not found") }
    guard detail.memo.state == .failed else {
      throw APIError.server(status: 409, body: ErrorBody(error: .badState, message: "retry needs a failed memo"))
    }
    detail.memo.state = .received
    detail.memo.failedStep = nil
    detail.memo.error = nil
    detail.memo.updatedAt = now()
    memos[id] = detail
    return detail.memo
  }

  /// Mirrors the server's rules without a runner: a parked memo becomes `routed` (nothing drives it on),
  /// a memo past `act` is left as it is, anything else is a 409.
  public func routeMemo(id: String, request: RouteRequest) async throws -> Memo {
    calls.append(.routeMemo(id: id, request: request))
    try failIfScripted(.routeMemo)
    guard var detail = memos[id] else { throw notFound("memo not found") }
    guard (request.destination == .herdr) == (request.tab != nil) else {
      throw APIError.server(
        status: 400, body: ErrorBody(error: .badRequest, message: "tab is required for herdr and only for herdr"))
    }
    switch detail.memo.state {
    case .needsRoute:
      detail.memo.state = .routed
      detail.memo.route = request.destination.rawValue
      detail.memo.routeReason = nil
      detail.memo.routeSuggestion = nil
      detail.memo.updatedAt = now()
      memos[id] = detail
    case .acted, .summarized, .notified:
      break
    default:
      throw APIError.server(
        status: 409, body: ErrorBody(error: .badState, message: "only parked or acted memos take a route"))
    }
    return detail.memo
  }

  public func listMemos(_ query: ListMemosQuery) async throws -> MemoPage {
    calls.append(.listMemos(query))
    try failIfScripted(.listMemos)
    let newestFirst = memos.values.map(\.memo).sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    let start = query.cursor.flatMap(Int.init) ?? 0
    let limit = query.limit ?? 50
    guard start < newestFirst.count else { return MemoPage(items: []) }
    let end = min(start + limit, newestFirst.count)
    return MemoPage(items: Array(newestFirst[start..<end]), nextCursor: end < newestFirst.count ? String(end) : nil)
  }

  public func memo(id: String) async throws -> MemoDetail {
    calls.append(.memo(id: id))
    try failIfScripted(.memo)
    guard let detail = memos[id] else { throw notFound("memo not found") }
    return detail
  }

  public func result(id: String, query: MemoResultQuery) async throws -> MemoResult {
    calls.append(.result(id: id, query: query))
    try failIfScripted(.result)
    if var queue = scriptedResults[id], !queue.isEmpty {
      let next = queue.removeFirst()
      scriptedResults[id] = queue
      return next
    }
    guard let detail = memos[id] else { throw notFound("memo not found") }
    return detail.memo.state.isResultReady ? .ready(detail.memo) : .pending(detail.memo)
  }

  public func registerDevice(_ request: RegisterDeviceRequest) async throws -> RegisterDeviceResponse {
    calls.append(.registerDevice(request))
    try failIfScripted(.registerDevice)
    var apnsEnv: APNsEnvironment?
    if case .set(let value) = request.apnsEnv { apnsEnv = value }
    return RegisterDeviceResponse(
      device: deviceID, name: request.name, platform: request.platform, apnsEnv: apnsEnv,
      hasApnsToken: Self.isSet(request.apnsToken), hasPushToStartToken: Self.isSet(request.pushToStartToken),
      registeredAt: now())
  }

  public func setActivityToken(memoID: String, request: ActivityTokenRequest) async throws {
    calls.append(.setActivityToken(memoID: memoID, request: request))
    try failIfScripted(.setActivityToken)
    guard memos[memoID] != nil else { throw notFound("memo not found") }
    activityTokens[memoID] = request.token
  }

  public func herd() async throws -> Herd {
    calls.append(.herd)
    try failIfScripted(.herd)
    return herdResponse
  }

  public nonisolated func events() -> AsyncThrowingStream<ServerEvent, any Error> {
    eventStream
  }

  // MARK: Helpers

  private func failIfScripted(_ endpoint: Endpoint) throws {
    guard var queue = failures[endpoint], !queue.isEmpty else { return }
    let error = queue.removeFirst()
    failures[endpoint] = queue
    throw error
  }

  private func notFound(_ message: String) -> APIError {
    .server(status: 404, body: ErrorBody(error: .notFound, message: message))
  }

  private static func isSet(_ update: FieldUpdate<String>) -> Bool {
    if case .set = update { return true }
    return false
  }
}
