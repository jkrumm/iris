import Foundation
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
    maxBackoff: Duration = .seconds(300)
  ) {
    self.buffer = buffer
    self.transport = transport
    self.resource = resource
    self.clock = clock
    self.batchSize = max(1, batchSize)
    self.interval = interval
    self.maxBackoff = maxBackoff
  }

  /// Sends everything buffered in batches of at most `batchSize`, stopping at the first failure. A call made while another flush
  /// is running waits for that flush, then returns; what was recorded since is picked up by one more pass.
  public func flush() async {
    if let running = inFlight {
      await running.value
      guard inFlight == nil, await buffer.pendingCount > 0 else { return }
    }
    let task = Task { await self.sendAll() }
    inFlight = task
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    inFlight = nil
  }

  private func sendAll() async {
    while !Task.isCancelled {
      let drain = await buffer.drain(max: batchSize)
      if drain.isEmpty { return }
      do {
        try await transport.send(TelemetryBatch(resource: resource, drain: drain))
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
