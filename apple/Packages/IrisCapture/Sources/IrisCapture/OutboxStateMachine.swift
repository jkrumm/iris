import Foundation

/// Pure outbox logic: no I/O, no clock, no tasks. `Outbox` drives it.
///
/// A queued item (a whole memo or chat message) goes through `create` (for a take: once it has a segment or has ended), then, for a take, its segments and `complete`:
/// - item create: pending -> uploading -> uploaded (voice) or gone (text), or uploading -> failed(retryAt) -> uploading;
/// - segments: pending -> uploading -> uploaded, or uploading -> failed(retryAt) -> uploading;
/// - `complete` for a memo is handed out only once the memo is finished and every segment `0..<segmentCount` is uploaded.
///
/// A transfer that fails `policy.maxAttempts` times, or is refused for good, **stalls**: nothing is scheduled until
/// `retryNow` or `discard`. Segments of a memo that has an item wait for the item's `create`; segments without an item
/// (the bare segment queue the tests drive) go out at once.
public struct OutboxStateMachine: Sendable {
  static let completedMemoLimit = 512

  private(set) var entries: [SegmentKey: OutboxEntry] = [:]
  private(set) var memos: [MemoID: OutboxMemo] = [:]
  private(set) var items: [MemoID: OutboxItem] = [:]
  private var nextSequence: Int
  /// Oldest first; bounded so the persisted record does not grow without limit. Holds the memos that completed and the
  /// ones that were discarded: both refuse a late `enqueue`.
  private var completedMemos: [MemoID]
  private let policy: OutboxPolicy

  /// Rebuilds the machine from persisted state. Transfers that were in flight when the app died
  /// go back to pending (the server is idempotent per segment and per memo id). A take the app died in the middle of
  /// is finished with the segments it had (contiguous from 0), or dropped when it had none.
  public init(record: OutboxRecord = OutboxRecord(), policy: OutboxPolicy = OutboxPolicy()) {
    self.policy = policy
    nextSequence = record.nextSequence
    completedMemos = Array(record.completedMemos.suffix(Self.completedMemoLimit))
    for var entry in record.entries {
      if entry.state == .uploading { entry.state = .pending }
      entries[entry.key] = entry
    }
    for var memo in record.memos {
      if memo.completion == .uploading { memo.completion = .pending }
      memos[memo.memoID] = memo
    }
    for var item in record.items {
      if item.create == .uploading { item.create = .pending }
      items[item.memoID] = item
    }
    recoverUnfinishedTakes()
  }

  public var record: OutboxRecord {
    OutboxRecord(
      entries: entries.values.sorted { $0.sequence < $1.sequence },
      memos: memos.values.sorted { $0.memoID.uuidString < $1.memoID.uuidString },
      items: orderedItems,
      nextSequence: nextSequence,
      completedMemos: completedMemos
    )
  }

  private var orderedItems: [OutboxItem] {
    items.values.sorted { ($0.queuedAt, $0.memoID.uuidString) < ($1.queuedAt, $1.memoID.uuidString) }
  }

  // MARK: Items

  /// Queues a whole memo or message. `false` when the memo id is already queued or already completed (or discarded).
  @discardableResult
  public mutating func enqueueItem(_ item: OutboxItem) -> Bool {
    guard items[item.memoID] == nil, !completedMemos.contains(item.memoID) else { return false }
    items[item.memoID] = item
    return true
  }

  /// Takes an item back out without a trace (its write failed): unlike `discard`, the id may be queued again.
  public mutating func withdrawItem(_ memoID: MemoID) {
    items[memoID] = nil
  }

  public mutating func createSucceeded(_ memoID: MemoID) {
    guard let item = items[memoID] else { return }
    switch item.kind {
    case .text: forget(memoID)
    case .voice:
      items[memoID]?.create = .uploaded
      items[memoID]?.lastError = nil
    }
  }

  public mutating func createFailed(_ memoID: MemoID, now: Date, permanent: Bool = false, reason: String? = nil) {
    guard var item = items[memoID] else { return }
    item.attempts += 1
    item.create = failedState(attempts: item.attempts, now: now, permanent: permanent)
    item.lastError = reason
    items[memoID] = item
  }

  public mutating func createCancelled(_ memoID: MemoID) {
    items[memoID]?.create = .pending
  }

  /// Puts every failed or stalled transfer of the memo back to pending with a fresh attempt count. `false` when
  /// there was nothing to retry.
  @discardableResult
  public mutating func retryNow(_ memoID: MemoID) -> Bool {
    var changed = false
    if var item = items[memoID], Self.isRetryable(item.create) {
      item.create = .pending
      item.attempts = 0
      item.lastError = nil
      items[memoID] = item
      changed = true
    }
    for (key, var entry) in entries where key.memoID == memoID && Self.isRetryable(entry.state) {
      entry.state = .pending
      entry.attempts = 0
      entries[key] = entry
      changed = true
    }
    if var memo = memos[memoID], Self.isRetryable(memo.completion) {
      memo.completion = .pending
      memo.attempts = 0
      memos[memoID] = memo
      changed = true
    }
    if changed { items[memoID]?.lastError = nil }
    return changed
  }

  /// Forgets the memo and everything queued for it; returns the segment files that are no longer needed. A segment of a
  /// discarded memo that shows up later (a take still closing) is refused.
  @discardableResult
  public mutating func discard(_ memoID: MemoID) -> [URL] {
    let files = entries.values.filter { $0.key.memoID == memoID }.map(\.segment.fileURL)
    forget(memoID)
    return files
  }

  /// The queue, oldest first, with where each item stands.
  public func queue() -> [OutboxQueueItem] {
    orderedItems.map { OutboxQueueItem(item: $0, status: status(of: $0)) }
  }

  private func status(of item: OutboxItem) -> OutboxItemStatus {
    let memo = memos[item.memoID]
    let states =
      [item.create] + entries.values.filter { $0.key.memoID == item.memoID }.map(\.state)
      + [memo?.completion].compactMap { $0 }
    if states.contains(.stalled) { return .failed(retryAt: nil, reason: item.lastError) }
    let retries = states.compactMap(Self.retryAt)
    if let soonest = retries.min() { return .failed(retryAt: soonest, reason: item.lastError) }
    if item.kind == .voice, memo == nil { return .recording }
    if states.contains(.uploading) { return .sending }
    return .waiting
  }

  /// A take that was recording when the app died: the segments it has are the take.
  private mutating func recoverUnfinishedTakes() {
    for item in items.values where item.kind == .voice && memos[item.memoID] == nil {
      let indices = Set(entries.keys.filter { $0.memoID == item.memoID }.map(\.index))
      var count = 0
      while indices.contains(count) { count += 1 }
      if count > 0 {
        memos[item.memoID] = OutboxMemo(memoID: item.memoID, segmentCount: count, completion: .pending, attempts: 0)
      } else {
        items[item.memoID] = nil
      }
    }
  }

  // MARK: Segments

  /// Returns `false` if (memo, index) is already known, whatever its state, or the memo already completed.
  @discardableResult
  public mutating func enqueue(_ segment: ClosedSegment) -> Bool {
    guard !completedMemos.contains(segment.memoID) else { return false }
    let key = SegmentKey(memoID: segment.memoID, index: segment.index)
    guard entries[key] == nil else { return false }
    entries[key] = OutboxEntry(segment: segment, sequence: nextSequence, state: .pending, attempts: 0)
    nextSequence += 1
    return true
  }

  /// A take with no segments has nothing to complete and is ignored, as is a memo that is already
  /// queued or already completed (a repeat must not resurrect it without its entries).
  public mutating func finishMemo(_ memoID: MemoID, segmentCount: Int) {
    guard segmentCount > 0, memos[memoID] == nil, !completedMemos.contains(memoID) else { return }
    memos[memoID] = OutboxMemo(memoID: memoID, segmentCount: segmentCount, completion: .pending, attempts: 0)
  }

  /// Hands out due work, oldest first, up to the concurrency cap, and marks it in flight: creates first (nothing else of
  /// that memo can move before its create), then completions, then segments.
  public mutating func dispatch(now: Date, inFlight: Int) -> [OutboxWork] {
    var capacity = policy.maxConcurrentUploads - inFlight
    var work: [OutboxWork] = []
    guard capacity > 0 else { return work }

    for item in orderedItems where capacity > 0 && isCreatable(item) && isDue(item.create, now: now) {
      items[item.memoID]?.create = .uploading
      var started = item
      started.create = .uploading
      work.append(.create(started))
      capacity -= 1
    }

    for memo in memos.values.sorted(by: { $0.memoID.uuidString < $1.memoID.uuidString }) {
      guard capacity > 0 else { break }
      guard isCreated(memo.memoID), isDue(memo.completion, now: now), allUploaded(memo) else { continue }
      memos[memo.memoID]?.completion = .uploading
      work.append(.complete(memo.memoID, segmentCount: memo.segmentCount))
      capacity -= 1
    }

    let due = entries.values.filter { isCreated($0.key.memoID) && isDue($0.state, now: now) }
      .sorted { $0.sequence < $1.sequence }
    for entry in due.prefix(capacity) {
      entries[entry.key]?.state = .uploading
      work.append(.upload(entry.segment))
    }
    return work
  }

  public mutating func uploadSucceeded(_ key: SegmentKey) {
    entries[key]?.state = .uploaded
    items[key.memoID]?.lastError = nil
  }

  public mutating func uploadFailed(_ key: SegmentKey, now: Date, permanent: Bool = false, reason: String? = nil) {
    guard var entry = entries[key] else { return }
    entry.attempts += 1
    entry.state = failedState(attempts: entry.attempts, now: now, permanent: permanent)
    entries[key] = entry
    items[key.memoID]?.lastError = reason
  }

  /// Shutdown or cancellation: not a failure, no backoff.
  public mutating func uploadCancelled(_ key: SegmentKey) {
    entries[key]?.state = .pending
  }

  /// The memo is done on the server: forget it, its segments and its item.
  public mutating func completeSucceeded(_ memoID: MemoID) {
    forget(memoID)
  }

  public mutating func completeFailed(_ memoID: MemoID, now: Date, permanent: Bool = false, reason: String? = nil) {
    guard var memo = memos[memoID] else { return }
    memo.attempts += 1
    memo.completion = failedState(attempts: memo.attempts, now: now, permanent: permanent)
    memos[memoID] = memo
    items[memoID]?.lastError = reason
  }

  public mutating func completeCancelled(_ memoID: MemoID) {
    memos[memoID]?.completion = .pending
  }

  /// The earliest future retry deadline, if any.
  public func nextWake(after now: Date) -> Date? {
    let deadlines =
      entries.values.compactMap { Self.retryAt($0.state) } + memos.values.compactMap { Self.retryAt($0.completion) }
      + items.values.compactMap { Self.retryAt($0.create) }
    return deadlines.filter { $0 > now }.min()
  }

  // MARK: Helpers

  private mutating func forget(_ memoID: MemoID) {
    if !completedMemos.contains(memoID) {
      completedMemos.append(memoID)
      completedMemos.removeFirst(max(0, completedMemos.count - Self.completedMemoLimit))
    }
    memos[memoID] = nil
    items[memoID] = nil
    entries = entries.filter { $0.key.memoID != memoID }
  }

  private func failedState(attempts: Int, now: Date, permanent: Bool) -> OutboxState {
    if permanent || attempts >= policy.maxAttempts { return .stalled }
    return .failed(retryAt: now.addingTimeInterval(policy.delay(forAttempt: attempts)))
  }

  private static func retryAt(_ state: OutboxState) -> Date? {
    guard case .failed(let date) = state else { return nil }
    return date
  }

  private static func isRetryable(_ state: OutboxState) -> Bool {
    switch state {
    case .failed, .stalled: true
    case .pending, .uploading, .uploaded: false
    }
  }

  /// A text item is created at once. A take is created once it has something to send (a closed segment, or its end), so
  /// a take that is cancelled before its first segment never reaches the server and leaves no stuck memo behind.
  private func isCreatable(_ item: OutboxItem) -> Bool {
    switch item.kind {
    case .text: true
    case .voice: memos[item.memoID] != nil || entries.keys.contains { $0.memoID == item.memoID }
    }
  }

  /// A memo without an item has no create to wait for.
  private func isCreated(_ memoID: MemoID) -> Bool {
    items[memoID].map { $0.create == .uploaded } ?? true
  }

  private func isDue(_ state: OutboxState, now: Date) -> Bool {
    switch state {
    case .pending: true
    case .failed(let retryAt): retryAt <= now
    case .uploading, .uploaded, .stalled: false
    }
  }

  private func allUploaded(_ memo: OutboxMemo) -> Bool {
    (0..<memo.segmentCount).allSatisfy {
      entries[SegmentKey(memoID: memo.memoID, index: $0)]?.state == .uploaded
    }
  }
}
