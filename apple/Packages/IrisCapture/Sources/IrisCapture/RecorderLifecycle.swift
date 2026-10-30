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

extension EngineStartup {
  /// Restarts a paused engine. When that fails (the configuration changed while it was paused, or the audio daemon was reset
  /// and the engine is dead) the engine is torn down and a fresh one is brought up with the tap on it; a failure of that is
  /// the caller's to report.
  static func resume<Engine: TapEngine>(_ engine: Engine, replacement: () -> Engine) throws -> Engine {
    do {
      try engine.start()
      return engine
    } catch {
      engine.removeTap()
      engine.stop()
      let fresh = replacement()
      try bringUp(fresh)
      return fresh
    }
  }
}

extension EngineStartup {
  /// Replaces an engine whose configuration changed. The old one is torn down first (its tap would collide with the new one
  /// and its input node may still describe the old hardware), then fresh engines are brought up until one holds, waiting with
  /// `pause` between attempts: the input is often not ready for a moment after a route change. `pause` answers `false` when the
  /// take has ended meanwhile, which abandons the restart (`nil`). The last error is thrown once the attempts run out.
  static func recover<Engine: TapEngine>(
    _ old: Engine, replacement: () -> Engine, attempts: Int, pause: () async -> Bool
  ) async throws -> Engine? {
    old.removeTap()
    old.stop()
    var lastError: any Error = CaptureError.engineFailure("no restart attempt was made")
    for attempt in 1...max(1, attempts) {
      let fresh = replacement()
      do {
        try bringUp(fresh)
        return fresh
      } catch {
        lastError = error
        guard attempt < attempts else { break }
        guard await pause() else { return nil }
      }
    }
    throw lastError
  }
}
