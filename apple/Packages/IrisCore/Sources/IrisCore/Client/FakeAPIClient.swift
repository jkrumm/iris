import Foundation

/// An in-memory `APIClient` for tests and previews in any package. It behaves like a small server:
/// memos are stored, segments are tracked, `complete` reports missing segments, `result` answers from
/// the stored state. It records every call and lets a test script failures and results.
public actor FakeAPIClient: APIClient {
  /// How long a deleted memo stays restorable (the server's purge window, 10 minutes).
  public static let purgeWindow: TimeInterval = 600

  /// A call as the client saw it. Segment bytes are reduced to their count.
  public enum Call: Hashable, Sendable {
    case health
    case whoami
    case createMemo(CreateMemoRequest)
    case createTextMemo(CreateTextMemoRequest)
    case uploadSegment(memoID: String, index: Int, byteCount: Int)
    case completeMemo(id: String, request: CompleteMemoRequest)
    case retryMemo(id: String, request: RetryMemoRequest)
    case routeMemo(id: String, request: RouteRequest)
    case setFlags(id: String, done: Bool?, favorite: Bool?, archived: Bool?)
    case deleteMemo(id: String)
    case restoreMemo(id: String)
    case listMemos(ListMemosQuery)
    case memo(id: String)
    case listThreads(ListThreadsQuery)
    case thread(id: String)
    case result(id: String, query: MemoResultQuery)
    case registerDevice(RegisterDeviceRequest)
    case setActivityToken(memoID: String, request: ActivityTokenRequest)
    case herd
    case stats(StatsQuery)
  }

  /// The endpoints a failure can be scripted for.
  public enum Endpoint: Hashable, Sendable {
    case health, whoami, createMemo, createTextMemo, uploadSegment, completeMemo, retryMemo, routeMemo
    case setFlags, deleteMemo, restoreMemo
    case listMemos, memo, listThreads, thread, result
    case registerDevice, setActivityToken, herd, stats
  }

  /// A response a test holds back. The call runs against the fake's state at once; only its answer waits.
  /// Create one with ``FakeAPIClient/hold(_:)``, wait for the call with ``waitUntilHeld()``, then ``release()``.
  public struct Gate: Sendable {
    private let held: AsyncStream<Void>
    private let heldSignal: AsyncStream<Void>.Continuation
    private let open: AsyncStream<Void>
    private let openSignal: AsyncStream<Void>.Continuation

    init() {
      (held, heldSignal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
      (open, openSignal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Returns once the held call has run and is waiting for ``release()``.
    public func waitUntilHeld() async {
      for await _ in held { return }
    }

    /// Lets the held call answer (with its result or its error). Releasing before the call arrives is fine.
    public func release() {
      openSignal.yield()
      openSignal.finish()
    }

    fileprivate func hold() async {
      heldSignal.yield()
      for await _ in open { return }
    }
  }

  public private(set) var calls: [Call] = []
  public private(set) var memos: [String: MemoDetail] = [:]
  public private(set) var threads: [String: ThreadDetail] = [:]
  public private(set) var segments: [String: [Int: Data]] = [:]
  public private(set) var activityTokens: [String: String] = [:]
  public var deviceID: String
  public var healthResponse = Health(status: .ok, degraded: [], inflight: 0)
  public var herdResponse = Herd(tabs: [])
  public var statsResponse = Stats(days: 30, from: "1970-01-01", to: "1970-01-30")

  private let now: @Sendable () -> Date
  private var failures: [Endpoint: [APIError]] = [:]
  private var gates: [Endpoint: [Gate]] = [:]
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

  /// Holds back the answer of the next call to `endpoint` (its result or its scripted failure) until the returned
  /// gate is released; the call's effect on the fake's state happens at once, as on a server whose response is slow.
  /// Queued gates are consumed one per call, in order. Gated endpoints: `health`, `listMemos`, `memo`, `setFlags`,
  /// `deleteMemo`, `restoreMemo`, `createTextMemo`, `setActivityToken` and `stats`.
  public func hold(_ endpoint: Endpoint) -> Gate {
    let gate = Gate()
    gates[endpoint, default: []].append(gate)
    return gate
  }

  /// Queues the answers `result(id:)` gives before it falls back to the stored memo's state.
  public func enqueueResults(_ results: [MemoResult], for memoID: String) {
    scriptedResults[memoID, default: []].append(contentsOf: results)
  }

  /// Stores a memo as if the server already had it.
  public func seed(_ detail: MemoDetail) {
    memos[detail.id] = detail
  }

  /// Stores a thread as if the server already had it; a memo may then continue it.
  public func seed(_ thread: ThreadDetail) {
    threads[thread.id] = thread
  }

  /// Moves a stored memo through the pipeline the way a running server would, without a runner: the memo takes `state`
  /// and, when given, the transcript, reply and summary; its thread (when it has one) follows with the user and assistant
  /// messages; `memo.updated` (and `memo.done` once result-ready) is emitted. An unknown id is a 404.
  public func advance(
    _ id: String, to state: MemoState, transcript: String? = nil, replyText: String? = nil, summary: MemoSummary? = nil
  ) throws {
    guard var detail = memos[id] else { throw notFound("memo not found") }
    let timestamp = now()
    detail.memo.state = state
    if let transcript { detail.memo.transcript = transcript }
    if let replyText { detail.memo.replyText = replyText }
    if let summary { detail.memo.summary = summary }
    detail.memo.updatedAt = timestamp
    store(detail)
    follow(detail.memo, transcript: transcript, replyText: replyText)
    let event = MemoEvent(id: id, state: state, at: timestamp)
    eventContinuation.yield(.memoUpdated(event))
    if state.isResultReady { eventContinuation.yield(.memoDone(event)) }
  }

  /// Mirrors a memo's new state into its thread: the memo itself, then its messages.
  private func follow(_ memo: Memo, transcript: String?, replyText: String?) {
    guard let threadId = memo.threadId, var thread = threads[threadId] else { return }
    if let index = thread.memos.firstIndex(where: { $0.id == memo.id }) { thread.memos[index] = memo }
    if let transcript, !thread.messages.contains(where: { $0.memoId == memo.id && $0.role == .user }) {
      thread.messages.append(
        ThreadMessage(memoId: memo.id, role: .user, content: transcript, createdAt: memo.createdAt))
    }
    if let replyText, !thread.messages.contains(where: { $0.memoId == memo.id && $0.role == .assistant }) {
      thread.messages.append(
        ThreadMessage(memoId: memo.id, role: .assistant, content: replyText, createdAt: memo.updatedAt))
    }
    thread.thread.updatedAt = memo.updatedAt
    thread.thread.lastMemoId = memo.id
    threads[threadId] = thread
  }

  public func setHealth(_ health: Health) { healthResponse = health }

  public func setHerd(_ herd: Herd) { herdResponse = herd }

  public func setStats(_ stats: Stats) { statsResponse = stats }

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
    return try await respond(.health) { healthResponse }
  }

  public func whoami() async throws -> Whoami {
    calls.append(.whoami)
    try failIfScripted(.whoami)
    return Whoami(device: deviceID)
  }

  public func createMemo(_ request: CreateMemoRequest) async throws -> Memo {
    calls.append(.createMemo(request))
    try failIfScripted(.createMemo)
    if let existing = memos[request.id]?.memo {
      try requireSameThread(existing, request.threadId)
      return existing
    }
    try requireThread(request.threadId)
    let timestamp = now()
    let memo = Memo(
      id: request.id, mode: request.mode, device: deviceID, startedAt: request.startedAt, state: .receiving,
      threadId: request.threadId, createdAt: timestamp, updatedAt: timestamp)
    memos[request.id] = MemoDetail(memo: memo, steps: [])
    attach(memo)
    return memo
  }

  /// Mirrors the server's rules without a runner: the memo is created `transcribed` and stays there.
  public func createTextMemo(_ request: CreateTextMemoRequest) async throws -> Memo {
    calls.append(.createTextMemo(request))
    return try await respond(.createTextMemo) { try storeTextMemo(request) }
  }

  private func storeTextMemo(_ request: CreateTextMemoRequest) throws -> Memo {
    let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.unicodeScalars.count <= CreateTextMemoRequest.maxTextCharacters else {
      throw APIError.server(
        status: 400, body: ErrorBody(error: .badRequest, message: "text must be 1-20000 characters"))
    }
    if let existing = memos[request.id]?.memo {
      guard existing.mode == request.mode, existing.startedAt == request.startedAt, existing.transcript == text,
        existing.isTyped, existing.threadId == request.threadId
      else {
        throw APIError.server(
          status: 409, body: ErrorBody(error: .conflict, message: "memo already exists with another body"))
      }
      return existing
    }
    try requireThread(request.threadId)
    let timestamp = now()
    let memo = Memo(
      id: request.id, mode: request.mode, device: deviceID, startedAt: request.startedAt, state: .transcribed,
      transcript: text, threadId: request.threadId, isTyped: true, createdAt: timestamp, updatedAt: timestamp)
    memos[request.id] = MemoDetail(memo: memo, steps: [])
    attach(memo)
    return memo
  }

  public func uploadSegment(memoID: String, index: Int, data: Data) async throws {
    calls.append(.uploadSegment(memoID: memoID, index: index, byteCount: data.count))
    try failIfScripted(.uploadSegment)
    guard let detail = memos[memoID] else { throw notFound("memo not found") }
    guard !detail.memo.isDeleted else { throw badState("memo \(memoID) is deleted") }
    segments[memoID, default: [:]][index] = data
  }

  public func completeMemo(id: String, request: CompleteMemoRequest) async throws -> Memo {
    calls.append(.completeMemo(id: id, request: request))
    try failIfScripted(.completeMemo)
    guard var detail = memos[id] else { throw notFound("memo not found") }
    guard !detail.memo.isDeleted else { throw badState("memo \(id) is deleted") }
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

  /// Soft-deletes (`DELETE`), flags (`PATCH`) and restores like the server; a deleted memo past `purgeWindow` is gone
  /// the next time anything looks, which is the server's purge.
  public func setFlags(id: String, done: Bool?, favorite: Bool?, archived: Bool?) async throws -> Memo {
    calls.append(.setFlags(id: id, done: done, favorite: favorite, archived: archived))
    return try await respond(.setFlags) {
      purgeExpired()
      guard var detail = memos[id] else { throw notFound("memo not found") }
      guard done != nil || favorite != nil || archived != nil else {
        throw APIError.server(
          status: 400, body: ErrorBody(error: .badRequest, message: "set at least one of done, favorite, archived"))
      }
      guard !detail.memo.isDeleted else { throw badState("memo \(id) is deleted") }
      if let done { detail.memo.done = done }
      if let favorite { detail.memo.favorite = favorite }
      if let archived { detail.memo.archived = archived }
      detail.memo.updatedAt = now()
      store(detail)
      return detail.memo
    }
  }

  public func deleteMemo(id: String) async throws -> Memo {
    calls.append(.deleteMemo(id: id))
    return try await respond(.deleteMemo) {
      purgeExpired()
      guard var detail = memos[id] else { throw notFound("memo not found") }
      if detail.memo.isDeleted { return detail.memo }
      guard detail.memo.state.isDeletable else {
        throw badState("memo \(id) is \(detail.memo.state.rawValue), only settled or receiving memos can be deleted")
      }
      let timestamp = now()
      detail.memo.deletedAt = timestamp
      detail.memo.purgeAt = timestamp.addingTimeInterval(Self.purgeWindow)
      detail.memo.updatedAt = timestamp
      store(detail)
      return detail.memo
    }
  }

  public func restoreMemo(id: String) async throws -> Memo {
    calls.append(.restoreMemo(id: id))
    return try await respond(.restoreMemo) {
      purgeExpired()
      guard var detail = memos[id] else { throw notFound("memo not found") }
      guard detail.memo.isDeleted else { throw badState("memo \(id) is not deleted") }
      detail.memo.deletedAt = nil
      detail.memo.purgeAt = nil
      detail.memo.updatedAt = now()
      store(detail)
      return detail.memo
    }
  }

  /// Mirrors the server's list rules: deleted memos never show, archived ones only with `archived`, and an open
  /// `needs_route` memo (not `done`) is pinned on the first page instead of paged.
  public func listMemos(_ query: ListMemosQuery) async throws -> MemoPage {
    calls.append(.listMemos(query))
    return try await respond(.listMemos) { page(for: query) }
  }

  private func page(for query: ListMemosQuery) -> MemoPage {
    purgeExpired()
    let matching = memos.values.map(\.memo)
      .filter { memo in
        !memo.isDeleted && memo.archived == query.archived && (!query.favorite || memo.favorite)
          && (query.route.map { memo.route == $0.rawValue } ?? true)
          && (query.state.map { memo.state == $0 } ?? true)
          && (query.kind.map { threads[memo.threadId ?? ""]?.thread.kind == $0 } ?? true)
          && Self.matches(memo, search: query.q)
      }
      .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    let isOpen: (Memo) -> Bool = { $0.state == .needsRoute && !$0.done }
    let pinned =
      query.cursor == nil && (query.state == nil || query.state == .needsRoute)
      ? Array(matching.filter(isOpen).prefix(50)) : []
    let newestFirst = matching.filter { !isOpen($0) }
    let start = query.cursor.flatMap(Int.init) ?? 0
    let limit = query.limit ?? 50
    guard start < newestFirst.count else { return MemoPage(items: [], pinned: pinned) }
    let end = min(start + limit, newestFirst.count)
    return MemoPage(
      items: Array(newestFirst[start..<end]), pinned: pinned, nextCursor: end < newestFirst.count ? String(end) : nil)
  }

  /// Every term of `search` is a case- and diacritic-insensitive prefix of a word of the transcript or headline.
  private static func matches(_ memo: Memo, search: String?) -> Bool {
    let terms = (search ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    if terms.isEmpty { return true }
    let words = [memo.transcript, memo.summary?.headline].compactMap { $0 }
      .flatMap { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) }
      .map { String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
    return terms.allSatisfy { term in
      let folded = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      return words.contains { $0.hasPrefix(folded) }
    }
  }

  public func memo(id: String) async throws -> MemoDetail {
    calls.append(.memo(id: id))
    return try await respond(.memo) {
      purgeExpired()
      guard let detail = memos[id] else { throw notFound("memo not found") }
      return detail
    }
  }

  public func listThreads(_ query: ListThreadsQuery) async throws -> ThreadPage {
    calls.append(.listThreads(query))
    try failIfScripted(.listThreads)
    let newestFirst = threads.values.map(\.thread)
      .filter { query.kind == nil || $0.kind == query.kind }
      .sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    let start = query.cursor.flatMap(Int.init) ?? 0
    let limit = query.limit ?? 20
    guard start < newestFirst.count else { return ThreadPage(items: []) }
    let end = min(start + limit, newestFirst.count)
    return ThreadPage(items: Array(newestFirst[start..<end]), nextCursor: end < newestFirst.count ? String(end) : nil)
  }

  public func thread(id: String) async throws -> ThreadDetail {
    calls.append(.thread(id: id))
    return try await respond(.thread) {
      guard let detail = threads[id] else { throw notFound("thread not found") }
      return detail
    }
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
    try await respond(.setActivityToken) {
      guard memos[memoID] != nil else { throw notFound("memo not found") }
      activityTokens[memoID] = request.token
    }
  }

  public func herd() async throws -> Herd {
    calls.append(.herd)
    try failIfScripted(.herd)
    return herdResponse
  }

  public func stats(_ query: StatsQuery) async throws -> Stats {
    calls.append(.stats(query))
    return try await respond(.stats) { statsResponse }
  }

  public nonisolated func events() -> AsyncThrowingStream<ServerEvent, any Error> {
    eventStream
  }

  // MARK: Helpers

  /// Runs `body` (after any scripted failure), then waits for a gate held on `endpoint` before answering.
  private func respond<T>(_ endpoint: Endpoint, _ body: () throws -> T) async throws -> T {
    let outcome = Result<T, any Error> {
      try failIfScripted(endpoint)
      return try body()
    }
    if var queue = gates[endpoint], !queue.isEmpty {
      let gate = queue.removeFirst()
      gates[endpoint] = queue
      await gate.hold()
    }
    return try outcome.get()
  }

  private func failIfScripted(_ endpoint: Endpoint) throws {
    guard var queue = failures[endpoint], !queue.isEmpty else { return }
    let error = queue.removeFirst()
    failures[endpoint] = queue
    throw error
  }

  /// A memo that names a thread must find it, as on the server.
  private func requireThread(_ threadId: String?) throws {
    guard let threadId, threads[threadId] == nil else { return }
    throw notFound("thread \(threadId) not found")
  }

  private func requireSameThread(_ memo: Memo, _ threadId: String?) throws {
    guard memo.threadId != threadId else { return }
    throw APIError.server(
      status: 409, body: ErrorBody(error: .conflict, message: "memo already exists with another thread"))
  }

  /// Files a new memo under its thread (its transcript becomes a user message) and moves the thread, as `act` does on the server.
  private func attach(_ memo: Memo) {
    guard let threadId = memo.threadId, var detail = threads[threadId] else { return }
    detail.memos.append(memo)
    if let transcript = memo.transcript {
      detail.messages.append(
        ThreadMessage(memoId: memo.id, role: .user, content: transcript, createdAt: memo.createdAt))
    }
    detail.thread.updatedAt = memo.updatedAt
    detail.thread.lastMemoId = memo.id
    threads[threadId] = detail
  }

  private func store(_ detail: MemoDetail) {
    memos[detail.id] = detail
  }

  /// The server's purger: a memo deleted longer ago than `purgeWindow` is gone.
  private func purgeExpired() {
    let cutoff = now()
    for (id, detail) in memos {
      if let purgeAt = detail.memo.purgeAt, purgeAt <= cutoff { memos[id] = nil }
    }
  }

  private func badState(_ message: String) -> APIError {
    .server(status: 409, body: ErrorBody(error: .badState, message: message))
  }

  private func notFound(_ message: String) -> APIError {
    .server(status: 404, body: ErrorBody(error: .notFound, message: message))
  }

  private static func isSet(_ update: FieldUpdate<String>) -> Bool {
    if case .set = update { return true }
    return false
  }
}
