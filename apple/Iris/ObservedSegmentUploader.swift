import Foundation
import IrisCapture
import IrisTelemetry
import Synchronization

/// The outbox's uploader with its calls on the device log: `outbox.segment.upload` per attempt and `outbox.complete.sent`.
/// A segment that closed (`capture.segment.closed`) and has no upload line is the data-loss alarm, visible while the take is
/// still running. Decorates the real uploader, so the outbox and the API adapter stay as they are.
nonisolated final class ObservedSegmentUploader: SegmentUploader {
  private let base: any SegmentUploader
  private let log: DeviceLog
  private let attempts = Mutex<[String: Int]>([:])

  init(_ base: any SegmentUploader, log: DeviceLog = .shared) {
    self.base = base
    self.log = log
  }

  func create(_ item: OutboxItem) async throws { try await base.create(item) }

  func upload(_ segment: ClosedSegment) async throws {
    let attempt = attempts.withLock { counts -> Int in
      let key = "\(segment.memoID)-\(segment.index)"
      counts[key, default: 0] += 1
      return counts[key] ?? 1
    }
    let started = ContinuousClock.now
    do {
      try await base.upload(segment)
      report(
        "outbox.segment.upload", segment.memoID, started, ["index": .int(segment.index), "attempt": .int(attempt)])
    } catch {
      report(
        "outbox.segment.upload", segment.memoID, started, ["index": .int(segment.index), "attempt": .int(attempt)],
        error)
      throw error
    }
  }

  func complete(memoID: MemoID, segmentCount: Int) async throws {
    let started = ContinuousClock.now
    do {
      try await base.complete(memoID: memoID, segmentCount: segmentCount)
      report("outbox.complete.sent", memoID, started, ["segment_count": .int(segmentCount)])
    } catch {
      report("outbox.complete.sent", memoID, started, ["segment_count": .int(segmentCount)], error)
      throw error
    }
  }

  func delete(memoID: MemoID) async throws { try await base.delete(memoID: memoID) }

  private func report(
    _ name: String, _ memoID: MemoID, _ started: ContinuousClock.Instant, _ attributes: [String: AttributeValue],
    _ error: (any Error)? = nil
  ) {
    var all = attributes
    let elapsed = ContinuousClock.now - started
    all["ms"] = .int(
      Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000))
    guard let error else {
      all["status"] = "ok"
      log.event(name, memoID: memoID, all)
      return
    }
    let (status, message) = Self.describe(error)
    all["status"] = .string(status)
    all["error"] = .string(message)
    log.event(name, memoID: memoID, severity: .warn, all)
  }

  /// `permanent` (stalls), `transient` (retried without counting) or `error` (retried, counts), and the error's type: never its
  /// message, which can be a server's own words.
  static func describe(_ error: any Error) -> (status: String, message: String) {
    let type = String(describing: Swift.type(of: error))
    switch error {
    case is PermanentTransferError: return ("permanent", type)
    case is TransientTransferError: return ("transient", type)
    default: return ("error", type)
    }
  }
}
