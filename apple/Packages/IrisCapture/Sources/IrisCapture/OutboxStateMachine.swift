import Foundation

/// Pure outbox logic: no I/O, no clock, no tasks. `Outbox` drives it.
///
/// Segment states: pending -> uploading -> uploaded, or uploading -> failed(retryAt) -> uploading.
/// `complete` for a memo is handed out only once the memo is finished and every segment
/// `0..<segmentCount` is uploaded.
public struct OutboxStateMachine: Sendable {
  private(set) var entries: [SegmentKey: OutboxEntry] = [:]
  private(set) var memos: [MemoID: OutboxMemo] = [:]
  private var nextSequence: Int
  private let policy: OutboxPolicy

  /// Rebuilds the machine from persisted state. Transfers that were in flight when the app died
  /// go back to pending (the server is idempotent per segment).
  public init(record: OutboxRecord = OutboxRecord(), policy: OutboxPolicy = OutboxPolicy()) {
    self.policy = policy
    nextSequence = record.nextSequence
    for var entry in record.entries {
      if entry.state == .uploading { entry.state = .pending }
      entries[entry.key] = entry
    }
    for var memo in record.memos {
      if memo.completion == .uploading { memo.completion = .pending }
      memos[memo.memoID] = memo
    }
  }

  public var record: OutboxRecord {
    OutboxRecord(
      entries: entries.values.sorted { $0.sequence < $1.sequence },
      memos: memos.values.sorted { $0.memoID.uuidString < $1.memoID.uuidString },
      nextSequence: nextSequence
    )
  }

  /// Returns `false` if (memo, index) is already known, whatever its state.
  @discardableResult
  public mutating func enqueue(_ segment: ClosedSegment) -> Bool {
    let key = SegmentKey(memoID: segment.memoID, index: segment.index)
    guard entries[key] == nil else { return false }
    entries[key] = OutboxEntry(segment: segment, sequence: nextSequence, state: .pending, attempts: 0)
    nextSequence += 1
    return true
  }

  /// A take with no segments has nothing to complete and is ignored.
  public mutating func finishMemo(_ memoID: MemoID, segmentCount: Int) {
    guard segmentCount > 0, memos[memoID] == nil else { return }
    memos[memoID] = OutboxMemo(memoID: memoID, segmentCount: segmentCount, completion: .pending, attempts: 0)
  }

  /// Hands out due work, oldest first, up to the concurrency cap, and marks it in flight.
  public mutating func dispatch(now: Date, inFlight: Int) -> [OutboxWork] {
    var capacity = policy.maxConcurrentUploads - inFlight
    var work: [OutboxWork] = []
    guard capacity > 0 else { return work }

    for memo in memos.values.sorted(by: { $0.memoID.uuidString < $1.memoID.uuidString }) {
      guard capacity > 0 else { break }
      guard isDue(memo.completion, now: now), allUploaded(memo) else { continue }
      memos[memo.memoID]?.completion = .uploading
      work.append(.complete(memo.memoID, segmentCount: memo.segmentCount))
      capacity -= 1
    }

    let due = entries.values.filter { isDue($0.state, now: now) }.sorted { $0.sequence < $1.sequence }
    for entry in due.prefix(capacity) {
      entries[entry.key]?.state = .uploading
      work.append(.upload(entry.segment))
    }
    return work
  }

  public mutating func uploadSucceeded(_ key: SegmentKey) {
    entries[key]?.state = .uploaded
  }

  public mutating func uploadFailed(_ key: SegmentKey, now: Date) {
    guard var entry = entries[key] else { return }
    entry.attempts += 1
    entry.state = .failed(retryAt: now.addingTimeInterval(policy.delay(forAttempt: entry.attempts)))
    entries[key] = entry
  }

  /// Shutdown or cancellation: not a failure, no backoff.
  public mutating func uploadCancelled(_ key: SegmentKey) {
    entries[key]?.state = .pending
  }

  /// The memo is done on the server: forget it and its segments.
  public mutating func completeSucceeded(_ memoID: MemoID) {
    memos[memoID] = nil
    entries = entries.filter { $0.key.memoID != memoID }
  }

  public mutating func completeFailed(_ memoID: MemoID, now: Date) {
    guard var memo = memos[memoID] else { return }
    memo.attempts += 1
    memo.completion = .failed(retryAt: now.addingTimeInterval(policy.delay(forAttempt: memo.attempts)))
    memos[memoID] = memo
  }

  public mutating func completeCancelled(_ memoID: MemoID) {
    memos[memoID]?.completion = .pending
  }

  /// The earliest future retry deadline, if any.
  public func nextWake(after now: Date) -> Date? {
    let deadlines = entries.values.compactMap { retryAt($0.state) } + memos.values.compactMap { retryAt($0.completion) }
    return deadlines.filter { $0 > now }.min()
  }

  private func retryAt(_ state: OutboxState) -> Date? {
    guard case .failed(let date) = state else { return nil }
    return date
  }

  private func isDue(_ state: OutboxState, now: Date) -> Bool {
    switch state {
    case .pending: true
    case .failed(let retryAt): retryAt <= now
    case .uploading, .uploaded: false
    }
  }

  private func allUploaded(_ memo: OutboxMemo) -> Bool {
    (0..<memo.segmentCount).allSatisfy {
      entries[SegmentKey(memoID: memo.memoID, index: $0)]?.state == .uploaded
    }
  }
}
