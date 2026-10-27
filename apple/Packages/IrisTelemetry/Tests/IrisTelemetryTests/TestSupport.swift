import Foundation
import Synchronization

@testable import IrisTelemetry

enum TestError: Error {
  case down
  case boom
}

enum Fixtures {
  static let epoch = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14T22:13:20Z
  static let memoID = UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E") ?? UUID()
  static let resource = TelemetryResource(serviceName: .ios, deviceName: "Test iPhone", appVersion: "1.2.3")

  static var traceID: TraceID { TraceID(memoID: memoID) }

  static func span(_ index: Int) -> SpanRecord {
    SpanRecord(
      traceID: traceID,
      spanID: SpanID(UInt64(index)),
      name: "span.\(index)",
      start: epoch.addingTimeInterval(Double(index)),
      end: epoch.addingTimeInterval(Double(index) + 0.5),
      attributes: ["index": .int(index)]
    )
  }

  static func log(_ index: Int) -> LogRecord {
    LogRecord(timestamp: epoch.addingTimeInterval(Double(index)), severity: .warn, body: "log.\(index)")
  }

  static func spanNames(_ batches: [TelemetryBatch]) -> [[String]] {
    batches.map { $0.spans.map(\.name) }
  }

  static func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "iris-telemetry-\(UUID().uuidString)", directoryHint: .isDirectory)
      .appending(path: "buffer.jsonl")
  }

  static func remove(_ fileURL: URL) {
    try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
  }
}

/// Counter-based ids: 1, 2, 3 ...
struct SequentialIDs: SpanIDGenerator {
  private var next: UInt64 = 1

  mutating func nextSpanID() -> SpanID {
    defer { next += 1 }
    return SpanID(next)
  }
}

/// A clock that only moves when the test says so. `now()` is an atomic read; sleepers are parked in an actor.
final class ManualClock: TelemetryClock {
  private let elapsedMilliseconds = Atomic<Int>(0)
  private let sleepers = Sleepers()
  private let start: Date

  init(start: Date = Fixtures.epoch) {
    self.start = start
  }

  func now() -> Date {
    start.addingTimeInterval(Double(elapsedMilliseconds.load(ordering: .acquiring)) / 1000)
  }

  func sleep(for duration: Duration) async throws {
    let deadline = elapsedMilliseconds.load(ordering: .acquiring) + Self.milliseconds(duration)
    try await sleepers.park(until: deadline, requested: duration)
  }

  func advance(by duration: Duration) async {
    let current = elapsedMilliseconds.add(Self.milliseconds(duration), ordering: .acquiringAndReleasing).newValue
    await sleepers.resumeDue(at: current)
  }

  /// Suspends until at least `count` tasks are parked in `sleep`.
  func untilSleeping(_ count: Int = 1) async {
    await sleepers.waitUntilParked(count)
  }

  var requestedSleeps: [Duration] {
    get async { await sleepers.requested }
  }

  private static func milliseconds(_ duration: Duration) -> Int {
    let parts = duration.components
    return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
  }

  private actor Sleepers {
    private struct Waiter {
      let deadline: Int
      let continuation: CheckedContinuation<Void, any Error>
    }

    private var waiters: [Int: Waiter] = [:]
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var nextID = 0
    private(set) var requested: [Duration] = []

    func park(until deadline: Int, requested duration: Duration) async throws {
      let id = nextID
      nextID += 1
      requested.append(duration)
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
          register(id, deadline: deadline, continuation: continuation)
        }
      } onCancel: {
        Task { await self.cancel(id) }
      }
    }

    private func register(_ id: Int, deadline: Int, continuation: CheckedContinuation<Void, any Error>) {
      if Task.isCancelled {
        continuation.resume(throwing: CancellationError())
        return
      }
      waiters[id] = Waiter(deadline: deadline, continuation: continuation)
      releaseWatchers()
    }

    func resumeDue(at now: Int) {
      for (id, waiter) in waiters where waiter.deadline <= now {
        waiters[id] = nil
        waiter.continuation.resume()
      }
    }

    func waitUntilParked(_ count: Int) async {
      if waiters.count >= count { return }
      await withCheckedContinuation { continuation in
        watchers.append((count, continuation))
      }
    }

    private func cancel(_ id: Int) {
      guard let waiter = waiters.removeValue(forKey: id) else { return }
      waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseWatchers() {
      let ready = watchers.filter { waiters.count >= $0.count }
      watchers.removeAll { waiters.count >= $0.count }
      for watcher in ready { watcher.continuation.resume() }
    }
  }
}

/// Records every batch; fails the first `failures` sends.
actor RecordingTransport: TelemetryTransport {
  private(set) var batches: [TelemetryBatch] = []
  private(set) var attempts = 0
  private var failuresRemaining: Int

  init(failures: Int = 0) {
    failuresRemaining = failures
  }

  func send(_ batch: TelemetryBatch) async throws {
    attempts += 1
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw TestError.down
    }
    batches.append(batch)
  }
}

/// A store whose every operation fails, to prove persistence trouble never reaches the caller.
struct FailingStore: TelemetryStore {
  func append(_ entries: [StoredEntry]) async throws { throw TestError.down }
  func load() async throws -> [StoredEntry] { throw TestError.down }
  func removeThrough(sequence: UInt64) async throws { throw TestError.down }
  func clear() async throws { throw TestError.down }
}
