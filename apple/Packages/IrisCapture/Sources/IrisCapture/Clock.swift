import Foundation

/// Wall-clock port for the outbox (retry deadlines are persisted, so they are `Date`s).
public protocol CaptureClock: Sendable {
  func now() async -> Date
  /// Returns when `now() >= deadline`. Throws `CancellationError` if the task is cancelled.
  func sleep(until deadline: Date) async throws
}

public struct SystemCaptureClock: CaptureClock {
  public init() {}

  public func now() async -> Date { Date() }

  public func sleep(until deadline: Date) async throws {
    let interval = deadline.timeIntervalSinceNow
    guard interval > 0 else { return }
    try await Task.sleep(for: .seconds(interval))
  }
}

/// A steppable clock for tests and `FakeCapture`: time only moves through `advance(by:)`.
public actor ManualClock: CaptureClock {
  private var current: Date
  private var nextSleeperID = 0
  private var sleepers: [Int: (deadline: Date, continuation: CheckedContinuation<Void, any Error>)] = [:]

  public init(start: Date = Date(timeIntervalSince1970: 1_000_000)) {
    current = start
  }

  public func now() -> Date { current }

  public func advance(by interval: TimeInterval) {
    current = current.addingTimeInterval(interval)
    let due = sleepers.filter { $0.value.deadline <= current }
    for (id, sleeper) in due {
      sleepers[id] = nil
      sleeper.continuation.resume()
    }
  }

  public func sleep(until deadline: Date) async throws {
    guard deadline > current else { return }
    let id = nextSleeperID
    nextSleeperID += 1
    try await withTaskCancellationHandler {
      try await suspend(id: id, deadline: deadline)
    } onCancel: {
      Task { await self.cancelSleeper(id) }
    }
  }

  private func suspend(id: Int, deadline: Date) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      if Task.isCancelled {
        continuation.resume(throwing: CancellationError())
        return
      }
      sleepers[id] = (deadline, continuation)
    }
  }

  private func cancelSleeper(_ id: Int) {
    guard let sleeper = sleepers.removeValue(forKey: id) else { return }
    sleeper.continuation.resume(throwing: CancellationError())
  }
}
