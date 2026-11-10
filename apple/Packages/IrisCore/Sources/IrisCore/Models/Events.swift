import Foundation

/// Payload of `memo.updated` and `memo.done` (the same shape; `memo.done` follows `memo.updated` when
/// the new state is result-ready).
public struct MemoEvent: Codable, Hashable, Sendable {
  public var id: String
  public var state: MemoState
  public var step: MemoStep?
  public var failedStep: MemoStep?
  public var error: String?
  public var at: Date

  public init(
    id: String,
    state: MemoState,
    step: MemoStep? = nil,
    failedStep: MemoStep? = nil,
    error: String? = nil,
    at: Date
  ) {
    self.id = id
    self.state = state
    self.step = step
    self.failedStep = failedStep
    self.error = error
    self.at = at
  }

  private enum CodingKeys: String, CodingKey {
    case id, state, step, failedStep, error, at
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(state, forKey: .state)
    try container.encode(step, forKey: .step)
    try container.encode(failedStep, forKey: .failedStep)
    try container.encode(error, forKey: .error)
    try container.encode(at, forKey: .at)
  }
}

/// Payload of the `ready` event: an empty object.
public struct ReadyEvent: Codable, Hashable, Sendable {
  public init() {}
}

/// Payload of `memo.delta`: the next piece of the reply while `act` runs. A client resets its buffer when `attempt` changes and
/// drops deltas of the same attempt with `seq` at or below a ``PartialReply``'s.
public struct MemoDelta: Codable, Hashable, Sendable {
  public var id: String
  public var attempt: Int
  public var seq: Int
  public var text: String

  public init(id: String, attempt: Int, seq: Int, text: String) {
    self.id = id
    self.attempt = attempt
    self.seq = seq
    self.text = text
  }
}

/// Payload of `memo.activity`: the name of a tool Hermes started (the same names as a memo's `actions`).
public struct MemoActivity: Codable, Hashable, Sendable {
  public var id: String
  public var attempt: Int
  public var tool: String

  public init(id: String, attempt: Int, tool: String) {
    self.id = id
    self.attempt = attempt
    self.tool = tool
  }
}

/// The reply text streamed so far, on a memo's detail while `act` runs (absent otherwise).
public struct PartialReply: Codable, Hashable, Sendable {
  public var attempt: Int
  public var seq: Int
  public var text: String

  public init(attempt: Int, seq: Int, text: String) {
    self.attempt = attempt
    self.seq = seq
    self.text = text
  }
}
