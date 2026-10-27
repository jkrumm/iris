/// Every enum here mirrors a closed vocabulary in `contracts/schema`. A new server value is a contract
/// change, so it fails fixture conformance instead of decoding to a silent fallback.

public enum MemoState: String, Codable, Hashable, Sendable, CaseIterable {
  case receiving
  case received
  case transcribed
  case routed
  case needsRoute = "needs_route"
  case acted
  case summarized
  case notified
  case failed

  /// No further pipeline progress without a retry.
  public var isTerminal: Bool { self == .notified || self == .failed }

  /// A `result` long-poll answers 200, and the server emits `memo.done`.
  public var isResultReady: Bool { isTerminal || self == .needsRoute }
}

/// The one tolerant enum: a mode this build does not know decodes to `.unknown` instead of failing the whole page
/// (an older client reading a list that holds memos of a newer mode). `.unknown` is not a mode to send and is not in `allCases`.
public enum MemoMode: String, Codable, Hashable, Sendable, CaseIterable {
  case auto
  case journal
  case hermes
  case tab
  case chat
  case unknown

  public static var allCases: [MemoMode] { [.auto, .journal, .hermes, .tab, .chat] }

  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = MemoMode(rawValue: raw) ?? .unknown
  }
}

/// A pipeline step, in execution order.
public enum MemoStep: String, Codable, Hashable, Sendable, CaseIterable {
  case ingest
  case transcribe
  case route
  case act
  case summarize
  case notify
}

/// A destination the user can route a memo to (`POST /v1/memos/:id/route`).
public enum RouteDestination: String, Codable, Hashable, Sendable, CaseIterable {
  case hermes
  case journal
  case herdr
}

public enum StepStatus: String, Codable, Hashable, Sendable, CaseIterable {
  case running
  case done
  case failed
}

public enum DevicePlatform: String, Codable, Hashable, Sendable, CaseIterable {
  case ios
  case macos
}

public enum APNsEnvironment: String, Codable, Hashable, Sendable, CaseIterable {
  case sandbox
  case production
}

public enum HealthStatus: String, Codable, Hashable, Sendable, CaseIterable {
  case ok
  case degraded
}

/// The agent state of a herdr tab. The schema's own `unknown` case covers anything herdr cannot classify.
public enum AgentState: String, Codable, Hashable, Sendable, CaseIterable {
  case idle
  case working
  case blocked
  case done
  case unknown
}

public enum LiveActivityPhase: String, Codable, Hashable, Sendable, CaseIterable {
  case processing
  case needsRoute
  case done
  case failed
}

/// The `error` discriminator of an API error body.
public enum APIErrorCode: String, Codable, Hashable, Sendable, CaseIterable {
  case notFound = "not_found"
  case conflict
  case badState = "bad_state"
  case missingSegments = "missing_segments"
  case tooLarge = "too_large"
  case badRequest = "bad_request"
  case unavailable
}
