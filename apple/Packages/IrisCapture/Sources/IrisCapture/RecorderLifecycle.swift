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
  /// Whether the engine is running right now (a system interruption or a configuration change stops it under us).
  var isRunning: Bool { get }
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
  /// Lets a take continue after a pause. A pause leaves the engine running with its tap and drops the samples, so the audio
  /// session stays hot and the app keeps its right to record: a resume from the island runs while the app is in the background,
  /// where starting a stopped engine fails (`!rec`, 561145187). Such an engine, still running, is kept as it is. One the
  /// system stopped meanwhile (an interruption, a configuration change) is not restarted on its old tap and format: it is
  /// replaced by a fresh one, retried like a restart (``recover(_:replacement:attempts:pause:)``). `nil` when the take ended
  /// while the input was not ready.
  static func resume<Engine: TapEngine>(
    _ engine: Engine, replacement: () -> Engine, attempts: Int, pause: () async -> Bool
  ) async throws -> Engine? {
    if engine.isRunning { return engine }
    return try await recover(engine, replacement: replacement, attempts: attempts, pause: pause)
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

/// Whether the engine is running, paused or being replaced, kept free of AVFoundation so the ordering rules are testable.
///
/// A configuration change tears the engine down and brings a fresh one up with `await`s in between. While that restart is in
/// flight `pause()` and `resume()` only record what the take should be doing; the engine they would act on is gone, and
/// starting it would leave a running engine without a tap that nothing owns. The restart applies the recorded state when it
/// finishes. A take that ends (or a new one that starts) meanwhile makes the restart's result stale.
struct EngineRun: Sendable, Equatable {
  /// What the caller does to the engine right now.
  enum Action: Sendable, Equatable {
    /// Nothing: a restart in flight will bring the engine up in the recorded state.
    case none
    /// Unused by the recorder: a pause keeps the engine running (it drops the samples), see ``EngineStartup/resume(_:replacement:attempts:pause:)``.
    case pauseEngine
    case startEngine
  }

  enum Verdict: Sendable, Equatable {
    /// The take ended or another began: tear the new engine down.
    case discard
    case keepRunning
    /// The take was paused while the engine came up: pause the new engine.
    case keepPaused
  }

  private(set) var isPaused = false
  private(set) var isRestarting = false
  private var generation = 0

  /// A take starts: running, nothing in flight, and any restart of an earlier take is stale.
  mutating func begin() {
    generation += 1
    isPaused = false
    isRestarting = false
  }

  /// The take ends: a restart in flight is stale.
  mutating func end() {
    generation += 1
    isRestarting = false
  }

  mutating func pause() -> Action {
    isPaused = true
    return isRestarting ? .none : .pauseEngine
  }

  /// `.startEngine` leaves `isPaused` for `resumed()` (a start that fails keeps the take paused).
  mutating func resume() -> Action {
    guard isRestarting else { return .startEngine }
    isPaused = false
    return .none
  }

  mutating func resumed() { isPaused = false }

  /// The generation to hand back to `endRestart`.
  mutating func beginRestart() -> Int {
    isRestarting = true
    return generation
  }

  mutating func endRestart(_ token: Int) -> Verdict {
    guard token == generation else { return .discard }
    isRestarting = false
    return isPaused ? .keepPaused : .keepRunning
  }
}
