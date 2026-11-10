import Foundation

/// A voice reply being started: it continues `threadId`, and the memo is created in `mode`.
public struct VoiceReplyRequest: Equatable, Sendable {
  public let threadId: String
  public let mode: MemoMode

  public init(threadId: String, mode: MemoMode) {
    self.threadId = threadId
    self.mode = mode
  }
}

/// How a voice take ended.
public enum VoiceReplyOutcome: Equatable, Sendable {
  /// Cancelled, or nothing was said: nothing is sent.
  case discarded
  /// The server has the memo (the recording is still on its way up).
  case sent(Memo)
  /// Recorded and kept in the outbox; it goes out by itself.
  case queued
  /// The recorder failed before anything was kept: the take is lost, and the user is told so.
  case recordingFailed
}

/// The capture port of a conversation screen: one take bound to a thread. Production is the app's outbox-backed capture (the
/// real recorder through the outbox; `-IrisFakeCapture` runs the same stack on fake audio), and an unconfigured build has
/// ``UnavailableVoiceReplyCapture``. Main-actor, so the app's main-actor class conforms without ceremony.
@MainActor
public protocol VoiceReplyCapture {
  /// `false` while nothing can record; the hold-to-talk control is then disabled.
  var isAvailable: Bool { get }
  /// Starts a take for the request.
  func begin(_ request: VoiceReplyRequest) async throws
  /// Ends the take. Cancelled: nothing is sent and the outcome is `.discarded`.
  func end(cancelled: Bool) async throws -> VoiceReplyOutcome
}

public struct UnavailableVoiceReplyCapture: VoiceReplyCapture {
  public init() {}
  public var isAvailable: Bool { false }
  public func begin(_ request: VoiceReplyRequest) async throws {}
  public func end(cancelled: Bool) async throws -> VoiceReplyOutcome { .discarded }
}
