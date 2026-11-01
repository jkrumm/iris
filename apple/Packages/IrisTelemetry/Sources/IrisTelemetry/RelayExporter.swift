import Foundation
import Synchronization
import os

/// Flushes the buffer to the server through a `TelemetryTransport`.
///
/// Triggers are explicit (`flush`, `flushOnBackground`, `flushOnLaunch`) plus `run()`, a loop that flushes every
/// `interval` on the injected clock. A failed send puts the data back, counts a failure and doubles the loop's wait
/// (capped at `maxBackoff`) until a send succeeds. Nothing here throws to callers, and recording never waits on a
/// flush: the buffer is a separate actor.
public actor RelayExporter {
  private let buffer: TelemetryBuffer
  private let transport: any TelemetryTransport
  private let resource: TelemetryResource
  private let clock: any TelemetryClock
  private let batchSize: Int
  private let interval: Duration
  private let maxBackoff: Duration
  private let sendTimeout: Duration
  private var consecutiveFailures = 0
  /// The flush running now. A second caller joins it: a background-task assertion must not end while its send is in flight.
  private var inFlight: Task<Void, Never>?

  public init(
    buffer: TelemetryBuffer,
    transport: any TelemetryTransport,
    resource: TelemetryResource,
    clock: any TelemetryClock = SystemTelemetryClock(),
    batchSize: Int = 100,
    interval: Duration = .seconds(10),
    maxBackoff: Duration = .seconds(300),
    sendTimeout: Duration = .seconds(20)
  ) {
    self.buffer = buffer
    self.transport = transport
    self.resource = resource
    self.clock = clock
    self.batchSize = max(1, batchSize)
    self.interval = interval
    self.maxBackoff = maxBackoff
    self.sendTimeout = sendTimeout
  }

  /// Sends everything buffered in batches of at most `batchSize`, stopping at the first failure. One flush runs at a time:
  /// a call made while another is running waits for it, and if nobody has started a new one by then, runs one more pass for
  /// what was recorded since. Two sends never overlap, so no batch is sent twice and an acknowledgement never removes a
  /// batch another send still holds.
  public func flush() async {
    if let running = inFlight {
      await Self.wait(for: running)
      // A caller that was cancelled while it waited (the background budget ran out) gives up; the flight goes on for its owner.
      if Task.isCancelled { return }
      // Back on the actor with no suspension until `inFlight` is set below: a flush that started meanwhile covers us.
      if let started = inFlight {
        await Self.wait(for: started)
        return
      }
    }
    let task = Task { await self.runFlight() }
    inFlight = task
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  /// Waits for another caller's flight, and returns early (leaving the flight alone) when the waiting caller is cancelled.
  /// `await task.value` alone ignores the waiter's cancellation, so a waiter with a deadline would outlive it.
  private static func wait(for flight: Task<Void, Never>) async {
    let resumer = WaitResumer()
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        resumer.install(continuation)
        Task {
          await flight.value
          resumer.fire()
        }
      }
    } onCancel: {
      resumer.fire()
    }
  }

  private func runFlight() async {
    await sendAll()
    inFlight = nil
  }

  private func sendAll() async {
    // A queue the last run left that could not be read yet (a phone not unlocked since boot) is retried here.
    await buffer.recover()
    while !Task.isCancelled {
      let drain = await buffer.drain(max: batchSize)
      if drain.isEmpty { return }
      do {
        try await send(TelemetryBatch(resource: resource, drain: drain))
      } catch {
        await buffer.requeue(drain)
        if !(error is CancellationError) {
          consecutiveFailures += 1
          Logger.telemetry.warning(
            "Telemetry flush failed (\(self.consecutiveFailures, privacy: .public) in a row): \(String(describing: type(of: error)), privacy: .public)"
          )
        }
        return
      }
      await buffer.acknowledge(drain)
      consecutiveFailures = 0
    }
  }

  /// One send, bounded by `sendTimeout` on the wall clock (not the injected one: a stuck connection is a real-time matter).
  /// A background-task assertion is held around a flush, so a send that never answers must end on its own.
  private func send(_ batch: TelemetryBatch) async throws {
    let transport = transport
    let timeout = sendTimeout
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await transport.send(batch) }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw TelemetryTransportError.timedOut
      }
      defer { group.cancelAll() }
      try await group.next()
    }
  }

  /// Call when the app moves to the background; the caller holds the background-task assertion around it.
  public func flushOnBackground() async {
    await flush()
  }

  /// Call at launch: recovers what the crash file holds, then flushes it.
  public func flushOnLaunch() async {
    await buffer.recover()
    await flush()
  }

  /// The periodic loop. Runs until the surrounding task is cancelled; the caller owns that task.
  public func run() async {
    while !Task.isCancelled {
      do {
        try await clock.sleep(for: delayBeforeNextFlush)
      } catch {
        return
      }
      await flush()
    }
  }

  private var delayBeforeNextFlush: Duration {
    guard consecutiveFailures > 0 else { return interval }
    return min(maxBackoff, interval * (1 << min(consecutiveFailures, 10)))
  }
}

/// Resumes one continuation exactly once, from whichever of the flight ending and the waiter's cancellation comes first, and
/// whether that is before or after the continuation is installed.
private final class WaitResumer: Sendable {
  private struct State {
    var continuation: CheckedContinuation<Void, Never>?
    var fired = false
  }

  private let state = Mutex(State())

  func install(_ continuation: CheckedContinuation<Void, Never>) {
    let resumeNow = state.withLock { state -> Bool in
      if state.fired { return true }
      state.continuation = continuation
      return false
    }
    if resumeNow { continuation.resume() }
  }

  func fire() {
    let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
      guard !state.fired else { return nil }
      state.fired = true
      defer { state.continuation = nil }
      return state.continuation
    }
    continuation?.resume()
  }
}
