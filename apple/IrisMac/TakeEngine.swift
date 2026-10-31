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
  /// The take closed no segment (nothing was said, or it was too short): there is no memo.
  case nothingRecorded
}

/// What the recording panel needs of a take, and nothing of how it is made.
/// Production: `CaptureTakeEngine` (the outbox stack on the Mac's audio devices). Fake: `FakeTakeEngine`.
protocol TakeEngine: Sendable {
  /// Input level 0...1 while a take runs.
  var levels: AsyncStream<Float> { get }
  /// The recorder failed mid-take (a write error, an engine that would not restart): one value per failure. One consumer.
  func failures() -> AsyncStream<Void>
  func microphones() async -> Microphones
  /// The microphone list when a device appears or goes, or the default changes. One consumer.
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
/// ``select(microphone:)`` and put back when the take ends, however it ends.
final class CaptureTakeEngine: TakeEngine {
  private let stack: CaptureStack
  private let routes: any RouteManager
  private let recorderLevels: AsyncStream<Float>
  private let title: String
  private static let logger = Logger(subsystem: "com.jkrumm.iris", category: "capture")

  init(
    stack: CaptureStack, routes: any RouteManager, levels: AsyncStream<Float>,
    title: String = String(localized: "Voice memo", comment: "Outbox row of a recorded memo")
  ) {
    self.stack = stack
    self.routes = routes
    recorderLevels = levels
    self.title = title
  }

  var levels: AsyncStream<Float> { recorderLevels }

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
    let changes = routes.routeChanges
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
    let session = try await stack.session()
    try await session.start(TakeRequest(mode: "auto", title: title))
    return await session.current.startedAt ?? Date()
  }

  func stop() async throws -> TakeEnd {
    do {
      let result = try await stack.session().stop()
      await restoreInput()
      return result == nil ? .nothingRecorded : .queued
    } catch {
      await restoreInput()
      throw error
    }
  }

  func cancel() async {
    if let session = try? await stack.session() { await session.cancel() }
    await restoreInput()
  }

  func select(microphone uid: String) async throws {
    try await stack.session().switchInput(to: uid)
  }

  private func restoreInput() async {
    do {
      try await routes.setPreferredInput(uid: nil)
    } catch {
      Self.logger.error("default input not restored: \(String(describing: error), privacy: .public)")
    }
  }
}

/// A scripted engine for tests and `-IrisFakeData`: no microphone, no outbox.
final class FakeTakeEngine: TakeEngine, @unchecked Sendable {
  static let microphones = Microphones(
    inputs: [FakeAudioDeviceDirectory.builtIn, FakeAudioDeviceDirectory.usb], current: FakeAudioDeviceDirectory.builtIn)

  let levels: AsyncStream<Float>
  private let failureStream: AsyncStream<Void>
  private let levelSink: AsyncStream<Float>.Continuation
  private let failureSink: AsyncStream<Void>.Continuation
  private let changes: AsyncStream<Microphones>
  private let changeSink: AsyncStream<Microphones>.Continuation
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

  init() {
    (levels, levelSink) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(1))
    (failureStream, failureSink) = AsyncStream.makeStream(of: Void.self)
    (changes, changeSink) = AsyncStream.makeStream(of: Microphones.self, bufferingPolicy: .bufferingNewest(1))
  }

  /// What the panel asked, in order: `start`, `stop`, `cancel`, `select:<uid>`.
  var calls: [String] { lock.withLock { state.calls } }

  /// Script hooks.
  func failStart(with error: (any Error)?) { lock.withLock { state.startError = error } }
  func failStop(with error: (any Error)?) { lock.withLock { state.stopError = error } }
  func endStop(with end: TakeEnd) { lock.withLock { state.end = end } }
  func level(_ value: Float) { levelSink.yield(value) }
  func fail() { failureSink.yield() }
  func setMicrophones(_ mics: Microphones) {
    lock.withLock { state.mics = mics }
    changeSink.yield(mics)
  }

  func failures() -> AsyncStream<Void> { failureStream }
  func microphones() async -> Microphones { lock.withLock { state.mics } }
  func microphoneChanges() -> AsyncStream<Microphones> { changes }

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
