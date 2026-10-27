import Foundation

/// The lifecycle of one take, kept free of AVFoundation so the reentrancy rules are unit-testable on the host.
///
/// `stop()` suspends while the sample stream drains. The phase flips to `.stopping` synchronously before that
/// suspension, so a second `stop()` (double tap) or a `start()` during the drain is rejected instead of
/// finalizing the take twice or resetting the rotator under the drain.
struct TakeLifecycle: Sendable, Equatable {
  enum Phase: Sendable, Equatable {
    case idle
    case recording(MemoID)
    case stopping(MemoID)
  }

  private(set) var phase: Phase = .idle

  /// The memo being recorded or drained; samples still flow while stopping.
  var activeMemoID: MemoID? {
    switch phase {
    case .idle: nil
    case .recording(let id), .stopping(let id): id
    }
  }

  /// Only a running take accepts rotate / pause / resume / configuration changes.
  var isRecording: Bool {
    if case .recording = phase { return true }
    return false
  }

  mutating func begin(_ memoID: MemoID) throws {
    guard phase == .idle else { throw CaptureError.alreadyRecording }
    phase = .recording(memoID)
  }

  /// A start that failed after `begin`: back to idle.
  mutating func abortStart() {
    guard isRecording else { return }
    phase = .idle
  }

  /// Claims the stop. Exactly one caller gets the memo id; any other gets `notRecording`.
  mutating func beginStop() throws -> MemoID {
    guard case .recording(let id) = phase else { throw CaptureError.notRecording }
    phase = .stopping(id)
    return id
  }

  mutating func finishStop() {
    phase = .idle
  }
}

/// The slice of the audio engine that start-up needs, so failure handling is testable without hardware.
protocol TapEngine {
  /// Removes the input tap on bus 0; harmless when none is installed.
  func removeTap()
  func installTap() throws
  func start() throws
  func stop()
}

enum EngineStartup {
  /// Installs the tap and starts the engine. A tap left on bus 0 would crash the next install with an
  /// Objective-C exception, so every failure path removes the tap and stops the engine before rethrowing.
  static func bringUp(_ engine: some TapEngine) throws {
    engine.removeTap()
    do {
      try engine.installTap()
      try engine.start()
    } catch {
      engine.removeTap()
      engine.stop()
      throw error
    }
  }
}
