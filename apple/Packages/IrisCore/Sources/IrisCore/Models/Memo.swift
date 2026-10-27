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
/// wire, unset ones as explicit `null`, which `encode(to:)` reproduces; the two exceptions are `routeReason`
/// and `routeSuggestion`, which are omitted when `nil`.
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
  /// Why the memo parked; present only while it is `needs_route`, omitted (never `null`) otherwise.
  public var routeReason: String?
  /// The decision model's best guess on a low-confidence park; same presence rule as `routeReason`.
  public var routeSuggestion: String?
  public var createdAt: Date
  public var updatedAt: Date

  /// Typed instead of spoken (`POST /v1/memos/text`): it never passed `received`, so past `receiving` it has no
  /// `segmentCount`. Such a memo has no recording (`GET /audio` has nothing to serve).
  public var isTyped: Bool { segmentCount == nil && state != .receiving }

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
    routeReason: String? = nil,
    routeSuggestion: String? = nil,
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
    self.routeReason = routeReason
    self.routeSuggestion = routeSuggestion
    self.createdAt = createdAt
    self.updatedAt = updatedAt
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
    try container.encodeIfPresent(routeReason, forKey: .routeReason)
    try container.encodeIfPresent(routeSuggestion, forKey: .routeSuggestion)
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

  public init(
    step: MemoStep,
    status: StepStatus,
    startedAt: Date,
    finishedAt: Date? = nil,
    error: String? = nil,
    usage: JSONValue? = nil,
    costUsd: Double? = nil
  ) {
    self.step = step
    self.status = status
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.error = error
    self.usage = usage
    self.costUsd = costUsd
  }

  private enum CodingKeys: String, CodingKey {
    case step, status, startedAt, finishedAt, error, usage, costUsd
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

/// `GET /v1/memos`: one page, newest first. `nextCursor` is `nil` on the last page.
public struct MemoPage: Codable, Hashable, Sendable {
  public var items: [Memo]
  public var nextCursor: String?

  public init(items: [Memo], nextCursor: String? = nil) {
    self.items = items
    self.nextCursor = nextCursor
  }

  private enum CodingKeys: String, CodingKey {
    case items, nextCursor
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(items, forKey: .items)
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
