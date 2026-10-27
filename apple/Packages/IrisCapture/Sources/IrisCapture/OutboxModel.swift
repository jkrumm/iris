import Foundation

public struct SegmentKey: Sendable, Hashable, Codable {
  public let memoID: MemoID
  public let index: Int

  public init(memoID: MemoID, index: Int) {
    self.memoID = memoID
    self.index = index
  }
}

public enum OutboxState: Sendable, Equatable, Codable {
  case pending
  case uploading
  case uploaded
  case failed(retryAt: Date)
}

public struct OutboxEntry: Sendable, Equatable, Codable {
  public var segment: ClosedSegment
  /// Enqueue order; uploads are dispatched oldest first.
  public var sequence: Int
  public var state: OutboxState
  public var attempts: Int

  public var key: SegmentKey { SegmentKey(memoID: segment.memoID, index: segment.index) }
}

/// A finished take waiting for its `complete` call.
public struct OutboxMemo: Sendable, Equatable, Codable {
  public let memoID: MemoID
  public let segmentCount: Int
  /// `.pending`, `.uploading` or `.failed`; the memo is removed once `complete` succeeds.
  public var completion: OutboxState
  public var attempts: Int
}

/// Everything the outbox persists.
public struct OutboxRecord: Sendable, Equatable, Codable {
  public var entries: [OutboxEntry]
  public var memos: [OutboxMemo]
  public var nextSequence: Int

  public init(entries: [OutboxEntry] = [], memos: [OutboxMemo] = [], nextSequence: Int = 0) {
    self.entries = entries
    self.memos = memos
    self.nextSequence = nextSequence
  }
}

public struct OutboxPolicy: Sendable {
  public var maxConcurrentUploads: Int
  public var baseDelay: TimeInterval
  public var maxDelay: TimeInterval
  /// The delay grows by up to this fraction, scaled by `jitter()`.
  public var jitterFraction: Double
  /// Returns a value in 0..<1. Injected so tests are deterministic.
  public var jitter: @Sendable () -> Double

  public init(
    maxConcurrentUploads: Int = 2,
    baseDelay: TimeInterval = 2,
    maxDelay: TimeInterval = 300,
    jitterFraction: Double = 0.25,
    jitter: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
  ) {
    self.maxConcurrentUploads = maxConcurrentUploads
    self.baseDelay = baseDelay
    self.maxDelay = maxDelay
    self.jitterFraction = jitterFraction
    self.jitter = jitter
  }

  /// Exponential backoff: `baseDelay * 2^(attempt-1)`, capped at `maxDelay`, plus jitter.
  /// `attempt` is the number of failures so far (1 for the first failure).
  public func delay(forAttempt attempt: Int) -> TimeInterval {
    let exponent = min(max(attempt - 1, 0), 30)
    let capped = min(maxDelay, baseDelay * Double(1 << exponent))
    return capped * (1 + jitterFraction * jitter())
  }
}

/// A unit of network work the state machine hands out.
public enum OutboxWork: Sendable, Equatable {
  case upload(ClosedSegment)
  case complete(MemoID, segmentCount: Int)
}
