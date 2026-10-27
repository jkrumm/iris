import Foundation

/// The `{headline, detail, spoken}` triage result.
public struct MemoSummary: Codable, Hashable, Sendable {
  public var headline: String
  public var detail: String
  public var spoken: String

  public init(headline: String, detail: String, spoken: String) {
    self.headline = headline
    self.detail = detail
    self.spoken = spoken
  }
}

/// A memo as returned by create, complete, retry, route, result and list. Every key is always present on the
/// wire, unset ones as explicit `null`, which `encode(to:)` reproduces; the exceptions are `routeReason`,
/// `routeSuggestion`, `threadId`, `typed`, `deletedAt` and `purgeAt`, which are omitted when `nil` / `false`.
public struct Memo: Codable, Hashable, Sendable, Identifiable {
  public var id: String
  public var mode: MemoMode
  public var device: String
  public var startedAt: Date
  public var state: MemoState
  public var failedStep: MemoStep?
  public var error: String?
  public var segmentCount: Int?
  public var audioSeconds: Double?
  public var transcript: String?
  public var route: String?
  public var destinationRef: String?
  public var replyText: String?
  public var summary: MemoSummary?
  /// The Hermes session (chat or not) the memo belongs to: set when `act` ran in it, or at creation for a memo that continues
  /// a thread (`CreateMemoRequest.threadId`); omitted (never `null`) otherwise.
  public var threadId: String?
  /// Why the memo parked; present only while it is `needs_route`, omitted (never `null`) otherwise.
  public var routeReason: String?
  /// The decision model's best guess on a low-confidence park; same presence rule as `routeReason`.
  public var routeSuggestion: String?
  /// User flags (swipe actions), always on the wire. None of them changes the pipeline; `done` dims a row, and a `done`
  /// `needs_route` memo is no longer pinned.
  public var done: Bool
  public var favorite: Bool
  public var archived: Bool
  /// Present only while the memo is soft-deleted: when it was deleted and when the server purges it for good. Until
  /// then `APIClient.restoreMemo(id:)` undoes the delete.
  public var deletedAt: Date?
  public var purgeAt: Date?
  public var createdAt: Date
  public var updatedAt: Date

  /// Typed instead of spoken (`POST /v1/memos/text`), the wire's `typed`: present and `true` only then. Such a
  /// memo has no recording (`GET /audio` is a 409). Read it from here, never derive it from `segmentCount`.
  public var isTyped: Bool

  /// Soft-deleted: awaiting the purge, restorable until `purgeAt`.
  public var isDeleted: Bool { deletedAt != nil }

  public init(
    id: String,
    mode: MemoMode,
    device: String,
    startedAt: Date,
    state: MemoState,
    failedStep: MemoStep? = nil,
    error: String? = nil,
    segmentCount: Int? = nil,
    audioSeconds: Double? = nil,
    transcript: String? = nil,
    route: String? = nil,
    destinationRef: String? = nil,
    replyText: String? = nil,
    summary: MemoSummary? = nil,
    threadId: String? = nil,
    routeReason: String? = nil,
    routeSuggestion: String? = nil,
    isTyped: Bool = false,
    done: Bool = false,
    favorite: Bool = false,
    archived: Bool = false,
    deletedAt: Date? = nil,
    purgeAt: Date? = nil,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.mode = mode
    self.device = device
    self.startedAt = startedAt
    self.state = state
    self.failedStep = failedStep
    self.error = error
    self.segmentCount = segmentCount
    self.audioSeconds = audioSeconds
    self.transcript = transcript
    self.route = route
    self.destinationRef = destinationRef
    self.replyText = replyText
    self.summary = summary
    self.threadId = threadId
    self.routeReason = routeReason
    self.routeSuggestion = routeSuggestion
    self.isTyped = isTyped
    self.done = done
    self.favorite = favorite
    self.archived = archived
    self.deletedAt = deletedAt
    self.purgeAt = purgeAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id, mode, device, startedAt, state, failedStep, error, segmentCount, audioSeconds, transcript, route
    case destinationRef, replyText, summary, threadId, routeReason, routeSuggestion, createdAt, updatedAt
    case done, favorite, archived, deletedAt, purgeAt
    case isTyped = "typed"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    mode = try container.decode(MemoMode.self, forKey: .mode)
    device = try container.decode(String.self, forKey: .device)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    state = try container.decode(MemoState.self, forKey: .state)
    failedStep = try container.decode(MemoStep?.self, forKey: .failedStep)
    error = try container.decode(String?.self, forKey: .error)
    segmentCount = try container.decode(Int?.self, forKey: .segmentCount)
    audioSeconds = try container.decode(Double?.self, forKey: .audioSeconds)
    transcript = try container.decode(String?.self, forKey: .transcript)
    route = try container.decode(String?.self, forKey: .route)
    destinationRef = try container.decode(String?.self, forKey: .destinationRef)
    replyText = try container.decode(String?.self, forKey: .replyText)
    summary = try container.decode(MemoSummary?.self, forKey: .summary)
    threadId = try container.decodeIfPresent(String.self, forKey: .threadId)
    routeReason = try container.decodeIfPresent(String.self, forKey: .routeReason)
    routeSuggestion = try container.decodeIfPresent(String.self, forKey: .routeSuggestion)
    isTyped = try container.decodeIfPresent(Bool.self, forKey: .isTyped) ?? false
    // Always sent by a server with flags; a missing key (an older server) reads as unset.
    done = try container.decodeIfPresent(Bool.self, forKey: .done) ?? false
    favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
    archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    purgeAt = try container.decodeIfPresent(Date.self, forKey: .purgeAt)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(mode, forKey: .mode)
    try container.encode(device, forKey: .device)
    try container.encode(startedAt, forKey: .startedAt)
    try container.encode(state, forKey: .state)
    try container.encode(failedStep, forKey: .failedStep)
    try container.encode(error, forKey: .error)
    try container.encode(segmentCount, forKey: .segmentCount)
    try container.encode(audioSeconds, forKey: .audioSeconds)
    try container.encode(transcript, forKey: .transcript)
    try container.encode(route, forKey: .route)
    try container.encode(destinationRef, forKey: .destinationRef)
    try container.encode(replyText, forKey: .replyText)
    try container.encode(summary, forKey: .summary)
    try container.encodeIfPresent(threadId, forKey: .threadId)
    try container.encodeIfPresent(routeReason, forKey: .routeReason)
    try container.encodeIfPresent(routeSuggestion, forKey: .routeSuggestion)
    if isTyped { try container.encode(true, forKey: .isTyped) }
    try container.encode(done, forKey: .done)
    try container.encode(favorite, forKey: .favorite)
    try container.encode(archived, forKey: .archived)
    try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    try container.encodeIfPresent(purgeAt, forKey: .purgeAt)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
  }
}

/// One row of a memo's step timeline. `usage` is open in the schema (audio seconds, token counts, ...),
/// so it stays a `JSONValue`; `nil` is JSON `null`.
public struct StepEntry: Codable, Hashable, Sendable {
  public var step: MemoStep
  public var status: StepStatus
  public var startedAt: Date
  public var finishedAt: Date?
  public var error: String?
  public var usage: JSONValue?
  public var costUsd: Double?
  /// Tries the step has used (1 unless the server retried a transient failure).
  public var attempts: Int

  public init(
    step: MemoStep,
    status: StepStatus,
    startedAt: Date,
    finishedAt: Date? = nil,
    error: String? = nil,
    usage: JSONValue? = nil,
    costUsd: Double? = nil,
    attempts: Int = 1
  ) {
    self.step = step
    self.status = status
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.error = error
    self.usage = usage
    self.costUsd = costUsd
    self.attempts = attempts
  }

  private enum CodingKeys: String, CodingKey {
    case step, status, startedAt, finishedAt, error, usage, costUsd, attempts
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    step = try container.decode(MemoStep.self, forKey: .step)
    status = try container.decode(StepStatus.self, forKey: .status)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
    error = try container.decodeIfPresent(String.self, forKey: .error)
    // `JSONValue` decodes `null` to `.null`; the model maps that to `nil`.
    let usage = try container.decodeIfPresent(JSONValue.self, forKey: .usage)
    self.usage = usage == .null ? nil : usage
    costUsd = try container.decodeIfPresent(Double.self, forKey: .costUsd)
    attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 1
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(step, forKey: .step)
    try container.encode(status, forKey: .status)
    try container.encode(startedAt, forKey: .startedAt)
    try container.encode(finishedAt, forKey: .finishedAt)
    try container.encode(error, forKey: .error)
    try container.encode(usage ?? .null, forKey: .usage)
    try container.encode(costUsd, forKey: .costUsd)
    try container.encode(attempts, forKey: .attempts)
  }
}

/// `GET /v1/memos/:id`: a memo plus its step timeline. On the wire the memo's keys and `steps` share
/// one flat object.
public struct MemoDetail: Codable, Hashable, Sendable, Identifiable {
  public var memo: Memo
  public var steps: [StepEntry]

  public var id: String { memo.id }

  public init(memo: Memo, steps: [StepEntry]) {
    self.memo = memo
    self.steps = steps
  }

  private enum CodingKeys: String, CodingKey {
    case steps
  }

  public init(from decoder: any Decoder) throws {
    memo = try Memo(from: decoder)
    steps = try decoder.container(keyedBy: CodingKeys.self).decode([StepEntry].self, forKey: .steps)
  }

  public func encode(to encoder: any Encoder) throws {
    try memo.encode(to: encoder)
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(steps, forKey: .steps)
  }
}

/// `GET /v1/memos`: one page, newest first. `nextCursor` is `nil` on the last page. `items` never holds an open
/// `needs_route` memo (one that is not `done`): the first page (no cursor) carries every one matching the filters in
/// `pinned` (newest first, at most 50), later pages carry none. Soft-deleted memos are in neither list.
public struct MemoPage: Codable, Hashable, Sendable {
  public var items: [Memo]
  public var pinned: [Memo]
  public var nextCursor: String?

  public init(items: [Memo], pinned: [Memo] = [], nextCursor: String? = nil) {
    self.items = items
    self.pinned = pinned
    self.nextCursor = nextCursor
  }

  private enum CodingKeys: String, CodingKey {
    case items, pinned, nextCursor
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    items = try container.decode([Memo].self, forKey: .items)
    pinned = try container.decodeIfPresent([Memo].self, forKey: .pinned) ?? []
    nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(items, forKey: .items)
    try container.encode(pinned, forKey: .pinned)
    try container.encode(nextCursor, forKey: .nextCursor)
  }
}

/// The answer to a `result` long-poll: HTTP 200 (`ready`) or 202 (`pending`, the wait elapsed first).
public enum MemoResult: Hashable, Sendable {
  case ready(Memo)
  case pending(Memo)

  public var memo: Memo {
    switch self {
    case .ready(let memo), .pending(let memo): memo
    }
  }
}
