import Foundation
import IrisCapture
import IrisCore
import os

/// The microphones of the Mac and the one in use.
struct Microphones: Equatable, Sendable {
  var inputs: [InputPort] = []
  var current: InputPort?
}

/// What stopping a take came to.
enum TakeEnd: Equatable, Sendable {
  /// The memo is in the outbox; the server gets it from there.
  case queued
  /// The recorder failed during the take (or stopping it timed out): the memo is in the outbox, but holds only what closed
  /// before that.
  case partial
  /// The take closed no segment (nothing was said, or it was too short): there is no memo.
  case nothingRecorded
}

/// What the recording panel needs of a take, and nothing of how it is made.
/// Production: `CaptureTakeEngine` (the outbox stack on the Mac's audio devices). Fake: `FakeTakeEngine`.
protocol TakeEngine: Sendable {
  /// Input level 0...1 while a take runs. Every read is its own subscription: a take's consumer ending must not end the next one's.
  var levels: AsyncStream<Float> { get }
  /// The recorder failed mid-take (a write error, an engine that would not restart): one value per failure.
  /// Every call is its own subscription.
  func failures() -> AsyncStream<Void>
  func microphones() async -> Microphones
  /// The microphone list when a device appears or goes, or the default changes. Every call is its own subscription.
  func microphoneChanges() -> AsyncStream<Microphones>
  /// Starts a take in mode Auto; returns the instant it started.
  func start() async throws -> Date
  func stop() async throws -> TakeEnd
  /// Drops the take: nothing is sent, its memo is deleted when the server already has it.
  func cancel() async
  func select(microphone uid: String) async throws
}

/// The production engine: one take through `IrisCapture`'s session and the persistent outbox (the same stack as the iPhone's,
/// on a Core Audio route manager), mode Auto like the iPhone's record control. The system default input is changed by
/// ``select(microphone:)`` and put back when the take ends, however it ends (and not over a default somebody else chose since).
final class CaptureTakeEngine: TakeEngine {
  private let stack: CaptureStack
  private let routes: any RouteManager
  private let created: CreatedMemoLog
  private let levelFeed = Broadcast<Float>()
  private let levelPump: Task<Void, Never>
  private let title: String
  private static let logger = Logger(subsystem: "com.jkrumm.iris", category: "capture")

  /// - Parameters:
  ///   - levels: the recorder's level stream, which has one consumer for the life of the recorder: the engine reads it once
  ///     and hands every take its own subscription.
  ///   - created: where a cancelled take's memo is forgotten, so History stops showing it while the server `DELETE` is pending.
  init(
    stack: CaptureStack, routes: any RouteManager, levels: AsyncStream<Float>, created: CreatedMemoLog,
    title: String = String(localized: "Voice memo", comment: "Outbox row of a recorded memo")
  ) {
    self.stack = stack
    self.routes = routes
    self.created = created
    self.title = title
    let feed = levelFeed
    // Owned by the engine (cancelled in `deinit`); runs for the life of the recorder, across takes.
    levelPump = Task {
      for await level in levels { feed.yield(level) }
    }
  }

  deinit { levelPump.cancel() }

  var levels: AsyncStream<Float> { levelFeed.subscribe() }

  /// The take's phase turning `failed`, read from the session (the recorder's own events belong to the session).
  func failures() -> AsyncStream<Void> {
    let stack = stack
    return AsyncStream { continuation in
      // Owned by the stream; ends with its consumer.
      let watching = Task {
        guard let session = try? await stack.session() else { return continuation.finish() }
        var wasFailed = false
        for await state in await session.updates() {
          if state.phase == .failed, !wasFailed { continuation.yield() }
          wasFailed = state.phase == .failed
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in watching.cancel() }
    }
  }

  func microphones() async -> Microphones {
    let route = await routes.currentRoute()
    return Microphones(inputs: route.availableInputs, current: route.currentInput)
  }

  func microphoneChanges() -> AsyncStream<Microphones> {
    let changes = routes.routeChanges  // its own subscription, taken now
    return AsyncStream { continuation in
      // Owned by the stream; ends with its consumer.
      let forwarding = Task {
        for await change in changes {
          continuation.yield(
            Microphones(inputs: change.snapshot.availableInputs, current: change.snapshot.currentInput))
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in forwarding.cancel() }
    }
  }

  func start() async throws -> Date {
    do {
      let session = try await stack.session()
      try await session.start(TakeRequest(mode: "auto", title: title))
      return await session.current.startedAt ?? Date()
    } catch {
      // The session may have applied a microphone rule (the default input changed) before the recorder refused.
      await restoreInput()
      throw error
    }
  }

  func stop() async throws -> TakeEnd {
    do {
      let result = try await stack.session().stop()
      await restoreInput()
      guard let result else { return .nothingRecorded }
      return result.failure == nil ? .queued : .partial
    } catch {
      await restoreInput()
      throw error
    }
  }

  /// Drops the take. The memo the session discarded is forgotten, so History hides it while the server `DELETE` is pending
  /// (the server may already have created it); a `stop` that won the session's gate sends the take, and nothing is hidden.
  func cancel() async {
    if let session = try? await stack.session(), let id = await session.cancel() {
      await created.forget(id.wireID)
    }
    await restoreInput()
  }

  func select(microphone uid: String) async throws {
    try await stack.session().switchInput(to: uid)
  }

  private func restoreInput() async {
    do {
      try await routes.setPreferredInput(uid: nil)
    } catch {
      Self.logger.error("default input not restored: \(logDescription(of: error), privacy: .public)")
    }
  }
}

/// A scripted engine for tests and `-IrisFakeData`: no microphone, no outbox.
final class FakeTakeEngine: TakeEngine, @unchecked Sendable {
  static let microphones = Microphones(
    inputs: [FakeAudioDeviceDirectory.builtIn, FakeAudioDeviceDirectory.usb], current: FakeAudioDeviceDirectory.builtIn)

  private let levelFeed = Broadcast<Float>()
  private let failureFeed = Broadcast<Void>()
  private let changeFeed = Broadcast<Microphones>()
  private let lock = NSLock()
  private var state = State()

  private struct State {
    var mics = FakeTakeEngine.microphones
    var running = false
    var startedAt = Date(timeIntervalSince1970: 0)
    var startError: (any Error)?
    var stopError: (any Error)?
    var end = TakeEnd.queued
    var calls: [String] = []
  }

  init() {}

  /// What the panel asked, in order: `start`, `stop`, `cancel`, `select:<uid>`.
  var calls: [String] { lock.withLock { state.calls } }

  /// Script hooks.
  func failStart(with error: (any Error)?) { lock.withLock { state.startError = error } }
  func failStop(with error: (any Error)?) { lock.withLock { state.stopError = error } }
  func endStop(with end: TakeEnd) { lock.withLock { state.end = end } }
  func level(_ value: Float) { levelFeed.yield(value) }
  func fail() { failureFeed.yield(()) }
  func setMicrophones(_ mics: Microphones) {
    lock.withLock { state.mics = mics }
    changeFeed.yield(mics)
  }

  var levels: AsyncStream<Float> { levelFeed.subscribe() }
  func failures() -> AsyncStream<Void> { failureFeed.subscribe() }
  func microphones() async -> Microphones { lock.withLock { state.mics } }
  func microphoneChanges() -> AsyncStream<Microphones> { changeFeed.subscribe() }

  func start() async throws -> Date {
    try lock.withLock {
      state.calls.append("start")
      if let error = state.startError { throw error }
      state.running = true
      state.startedAt = Date()
      return state.startedAt
    }
  }

  func stop() async throws -> TakeEnd {
    try lock.withLock {
      state.calls.append("stop")
      if let error = state.stopError { throw error }
      state.running = false
      return state.end
    }
  }

  func cancel() async {
    lock.withLock {
      state.calls.append("cancel")
      state.running = false
    }
  }

  func select(microphone uid: String) async throws {
    lock.withLock {
      state.calls.append("select:\(uid)")
      if let port = state.mics.inputs.first(where: { $0.uid == uid }) { state.mics.current = port }
    }
  }
}

/// An error for the log, without what it carries: a `CaptureError` names the microphone's uid, and a device uid is never logged.
func logDescription(of error: any Error) -> String {
  let bridged = error as NSError
  return "\(type(of: error)) (\(bridged.domain) \(bridged.code))"
}
