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

  /// `DELETE /v1/memos/:id` accepts the memo: the pipeline is done with it, or it is a take still `receiving` (a cancelled
  /// take; its later segment and `complete` are then 409). Any other state is a 409.
  public var isDeletable: Bool { isResultReady || self == .receiving }
}

/// Every memo goes to Hermes except `transcribe`. Decoding is tolerant: any other string (the retired `auto`, `chat`,
/// `journal`, `tab`, or one this build does not know) reads as `.hermes`.
public enum MemoMode: String, Codable, Hashable, Sendable, CaseIterable {
  case hermes
  /// Transcript only: the pipeline stops after `transcribe` (no act or summarize) and the memo ends `notified`.
  case transcribe

  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = MemoMode(rawValue: raw) ?? .hermes
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

/// The phase of the Live Activity. `recording`, `paused` and `uploading` are the client's own, set locally while the take
/// is on the phone; the server's pushes only ever carry `processing`, `done` and `failed`.
public enum LiveActivityPhase: String, Codable, Hashable, Sendable, CaseIterable {
  case recording
  case paused
  case uploading
  case processing
  case done
  case failed

  /// A phase only the device sets while it owns the take. The server never pushes one, so a Live Activity still in one of
  /// them after the app was relaunched has no one left to move it on.
  public var isClientPhase: Bool {
    switch self {
    case .recording, .paused, .uploading: true
    case .processing, .done, .failed: false
    }
  }
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
  case destinationUnavailable = "destination_unavailable"
}
