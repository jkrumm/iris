import Foundation

/// Pure outbox logic: no I/O, no clock, no tasks. `Outbox` drives it.
///
/// A queued item (a whole memo or chat message) goes through `create` (for a take: once it has a segment or has ended), then, for a take, its segments and `complete`:
/// - item create: pending -> uploading -> uploaded (voice) or gone (text), or uploading -> failed(retryAt) -> uploading;
/// - segments: pending -> uploading -> uploaded, or uploading -> failed(retryAt) -> uploading;
/// - `complete` for a memo is handed out only once the memo is finished and every segment `0..<segmentCount` is uploaded.
///
/// A transfer that fails `policy.maxAttempts` times, or is refused for good, **stalls**: nothing is scheduled until
/// `retryNow` or `discard`. A transient failure (no network, a 5xx) backs off but never stalls, however long it lasts:
/// the attempt count then only sets the delay. Segments of a memo that has an item wait for the item's `create`; segments without an item
/// (the bare segment queue the tests drive) go out at once.
public struct OutboxStateMachine: Sendable {
  static let completedMemoLimit = 512

  private(set) var entries: [SegmentKey: OutboxEntry] = [:]
  private(set) var memos: [MemoID: OutboxMemo] = [:]
  private(set) var items: [MemoID: OutboxItem] = [:]
  private(set) var deletions: [MemoID: OutboxDeletion] = [:]
  private var nextSequence: Int
  /// Items whose first save has not landed: in the queue, but never handed out, because the caller may still be told the
  /// queue refused them. Not persisted (after a relaunch an item on disk was saved).
  private var withheld: Set<MemoID> = []
  /// Segments whose first save has not landed: queued, but never uploaded, because a crash now would lose a segment the
  /// server already has. Not persisted.
  private var withheldSegments: Set<SegmentKey> = []
  /// Deletions held back while the discarded take's `create` may still be on the wire: the `DELETE` must come after it.
  /// Not persisted (after a relaunch nothing is on the wire).
  private var withheldDeletions: Set<MemoID> = []
  /// Takes the app died in the middle of, finished by `recoverUnfinishedTakes` with the segments the saved queue had. Not
  /// persisted: only the load that recovered them may add the segment files that never made it into the saved queue.
  private var recoveredTakes: Set<MemoID> = []
  /// `createMayHaveLanded` as it was before `dispatch` handed the create out, for `revertDispatch`. Not persisted.
  private var flagBeforeDispatch: [MemoID: Bool] = [:]
  /// Memos discarded in this run, so a follower can tell a discard from a memo the server has completed.
  private var discarded: Set<MemoID> = []
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
    for var deletion in record.deletions {
      if deletion.state == .uploading { deletion.state = .pending }
      deletions[deletion.memoID] = deletion
    }
    recoverUnfinishedTakes()
  }

  public var record: OutboxRecord {
    OutboxRecord(
      entries: entries.values.sorted { $0.sequence < $1.sequence },
      memos: memos.values.sorted { $0.memoID.uuidString < $1.memoID.uuidString },
      items: orderedItems,
      deletions: deletions.values.sorted { $0.memoID.uuidString < $1.memoID.uuidString },
      nextSequence: nextSequence,
      completedMemos: completedMemos
    )
  }

  private var orderedItems: [OutboxItem] {
    items.values.sorted { ($0.queuedAt, $0.memoID.uuidString) < ($1.queuedAt, $1.memoID.uuidString) }
  }

  // MARK: Items

  /// Queues a whole memo or message. `false` when the memo id is already queued or already completed (or discarded).
  ///
  /// With `withheld`, the item is held back from `dispatch` until `release(_:)`: the caller saves the queue first and only
  /// then lets the item go out (or `withdrawItem`s it).
  @discardableResult
  public mutating func enqueueItem(_ item: OutboxItem, withheld: Bool = false) -> Bool {
    guard items[item.memoID] == nil, !completedMemos.contains(item.memoID) else { return false }
    items[item.memoID] = item
    if withheld { self.withheld.insert(item.memoID) }
    return true
  }

  /// Lets a withheld item go out.
  public mutating func release(_ memoID: MemoID) {
    withheld.remove(memoID)
  }

  /// Takes an item back out without a trace (its write failed): unlike `discard`, the id may be queued again.
  public mutating func withdrawItem(_ memoID: MemoID) {
    items[memoID] = nil
    withheld.remove(memoID)
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

  public mutating func createFailed(
    _ memoID: MemoID, now: Date, permanent: Bool = false, transient: Bool = false, reason: String? = nil
  ) {
    guard var item = items[memoID] else { return }
    item.attempts += 1
    item.create = failedState(attempts: item.attempts, now: now, permanent: permanent, transient: transient)
    item.lastError = reason
    // A refusal for good means the memo was not made (a 409 can even mean another device's id): nothing of ours to delete.
    if permanent { item.createMayHaveLanded = false }
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
    if var deletion = deletions[memoID], Self.isRetryable(deletion.state) {
      deletion.state = .pending
      deletion.attempts = 0
      deletion.lastError = nil
      deletions[memoID] = deletion
      changed = true
    }
    if changed { items[memoID]?.lastError = nil }
    return changed
  }

  /// Every transfer that is waiting out a backoff becomes due now (the connection came back, the app is in front again).
  /// Stalled transfers stay as they are: only `retryNow` moves those. `false` when nothing was waiting.
  @discardableResult
  public mutating func retryBackedOff() -> Bool {
    var changed = false
    for (id, item) in items where Self.isBackedOff(item.create) {
      items[id]?.create = .pending
      changed = true
    }
    for (key, entry) in entries where Self.isBackedOff(entry.state) {
      entries[key]?.state = .pending
      changed = true
    }
    for (id, memo) in memos where Self.isBackedOff(memo.completion) {
      memos[id]?.completion = .pending
      changed = true
    }
    for (id, deletion) in deletions where Self.isBackedOff(deletion.state) {
      deletions[id]?.state = .pending
      changed = true
    }
    return changed
  }

  /// Whether discarding this memo has to delete it on the server too: a take whose `create` has been sent and not refused
  /// (it may have landed even if the answer was lost, or the app was killed with the request on the wire). A text item, a
  /// take that was never created and an item the server refused leave nothing of ours behind.
  public func needsServerDelete(_ memoID: MemoID) -> Bool {
    guard let item = items[memoID], item.kind == .voice else { return false }
    return item.createMayHaveLanded
  }

  /// Forgets the memo and everything queued for it; returns the segment files that are no longer needed. A segment of a
  /// discarded memo that shows up later (a take still closing) is refused. With `deleteOnServer` the memo's `DELETE` is
  /// queued (withheld until `releaseDeletion`).
  @discardableResult
  public mutating func discard(_ memoID: MemoID, deleteOnServer: Bool = false) -> [URL] {
    let files = entries.values.filter { $0.key.memoID == memoID }.map(\.segment.fileURL)
    let item = items[memoID]
    forget(memoID)
    discarded.insert(memoID)
    if deleteOnServer {
      deletions[memoID] = OutboxDeletion(
        memoID: memoID, title: item?.title ?? "", queuedAt: item?.queuedAt ?? Date())
      withheldDeletions.insert(memoID)
    }
    return files
  }

  /// Lets a queued `DELETE` go out (the discarded take's `create` is no longer on the wire).
  public mutating func releaseDeletion(_ memoID: MemoID) {
    withheldDeletions.remove(memoID)
  }

  /// The memo was discarded in this run (so its leaving the queue is not a completed upload).
  public func wasDiscarded(_ memoID: MemoID) -> Bool { discarded.contains(memoID) }

  public mutating func deleteSucceeded(_ memoID: MemoID) {
    deletions[memoID] = nil
  }

  /// A failed `DELETE` is kept: it backs off, and once it stalls (a refusal the server will repeat, or out of attempts) it
  /// waits in the queue for "retry now" or the user's `abandonDeletion`. It is never dropped silently.
  public mutating func deleteFailed(
    _ memoID: MemoID, now: Date, permanent: Bool = false, transient: Bool = false, reason: String? = nil
  ) {
    guard var deletion = deletions[memoID] else { return }
    deletion.attempts += 1
    deletion.state = failedState(attempts: deletion.attempts, now: now, permanent: permanent, transient: transient)
    deletion.lastError = reason
    deletions[memoID] = deletion
  }

  /// The user gives up on removing the discarded memo from the server.
  public mutating func abandonDeletion(_ memoID: MemoID) {
    deletions[memoID] = nil
    withheldDeletions.remove(memoID)
  }

  public mutating func deleteCancelled(_ memoID: MemoID) {
    deletions[memoID]?.state = .pending
  }

  /// The queue, oldest first, with where each item stands.
  public func queue() -> [OutboxQueueItem] {
    let removals = deletions.values.map { deletion in
      OutboxQueueItem(item: Self.row(of: deletion), status: status(of: deletion), isDeletion: true)
    }
    let rows = orderedItems.map { OutboxQueueItem(item: $0, status: status(of: $0)) } + removals
    return rows.sorted { ($0.item.queuedAt, $0.id.uuidString) < ($1.item.queuedAt, $1.id.uuidString) }
  }

  /// A discarded take's pending `DELETE` as the queue row it shows.
  private static func row(of deletion: OutboxDeletion) -> OutboxItem {
    OutboxItem(
      memoID: deletion.memoID, kind: .voice, mode: "", startedAt: deletion.queuedAt, queuedAt: deletion.queuedAt,
      title: deletion.title)
  }

  private func status(of deletion: OutboxDeletion) -> OutboxItemStatus {
    switch deletion.state {
    case .pending, .uploaded: .waiting
    case .uploading: .sending
    case .failed(let retryAt): .failed(retryAt: retryAt, reason: deletion.lastError)
    case .stalled: .failed(retryAt: nil, reason: deletion.lastError)
    }
  }

  private func status(of item: OutboxItem) -> OutboxItemStatus {
    let memo = memos[item.memoID]
    // A take that is still being recorded is a live take whatever its create is doing: Settings must not offer to retry
    // or discard it while the recorder runs.
    if item.kind == .voice, memo == nil { return .recording }
    let states =
      [item.create] + entries.values.filter { $0.key.memoID == item.memoID }.map(\.state)
      + [memo?.completion].compactMap { $0 }
    if states.contains(.stalled) { return .failed(retryAt: nil, reason: item.lastError) }
    let retries = states.compactMap(Self.retryAt)
    if let soonest = retries.min() { return .failed(retryAt: soonest, reason: item.lastError) }
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
        recoveredTakes.insert(item.memoID)
      } else {
        items[item.memoID] = nil
      }
    }
  }

  // MARK: Segments

  /// Returns `false` if (memo, index) is already known, whatever its state, or the memo already completed.
  ///
  /// With `withheld`, the segment is held back from `dispatch` until `release(_:)`: the caller saves the queue first.
  @discardableResult
  public mutating func enqueue(_ segment: ClosedSegment, withheld: Bool = false) -> Bool {
    guard !completedMemos.contains(segment.memoID) else { return false }
    let key = SegmentKey(memoID: segment.memoID, index: segment.index)
    guard entries[key] == nil else { return false }
    entries[key] = OutboxEntry(segment: segment, sequence: nextSequence, state: .pending, attempts: 0)
    nextSequence += 1
    if withheld { withheldSegments.insert(key) }
    return true
  }

  /// Takes in a segment file the saved queue never named (the startup sweep): it fills an index below the take's count, or,
  /// for a take recovered after a crash, the next index after it (the take grows). `false` when the segment does not belong
  /// to a take this queue holds or would not fit; the caller quarantines the file. Held back like any new segment.
  public mutating func adopt(_ segment: ClosedSegment) -> Bool {
    guard items[segment.memoID]?.kind == .voice, let memo = memos[segment.memoID],
      entries[SegmentKey(memoID: segment.memoID, index: segment.index)] == nil
    else { return false }
    let grows = segment.index == memo.segmentCount && recoveredTakes.contains(memo.memoID)
    guard segment.index < memo.segmentCount || grows else { return false }
    guard enqueue(segment, withheld: true) else { return false }
    if grows { memos[memo.memoID]?.segmentCount += 1 }
    return true
  }

  /// Lets a withheld segment go out.
  public mutating func release(_ key: SegmentKey) {
    withheldSegments.remove(key)
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
      flagBeforeDispatch[item.memoID] = item.createMayHaveLanded
      items[item.memoID]?.createMayHaveLanded = true
      var started = item
      started.create = .uploading
      started.createMayHaveLanded = true
      work.append(.create(started))
      capacity -= 1
    }

    for deletion in deletions.values.sorted(by: { $0.memoID.uuidString < $1.memoID.uuidString })
    where capacity > 0 && !withheldDeletions.contains(deletion.memoID) && isDue(deletion.state, now: now) {
      deletions[deletion.memoID]?.state = .uploading
      work.append(.delete(deletion.memoID))
      capacity -= 1
    }

    for memo in memos.values.sorted(by: { $0.memoID.uuidString < $1.memoID.uuidString }) {
      guard capacity > 0 else { break }
      guard isCreated(memo.memoID), isDue(memo.completion, now: now), allUploaded(memo) else { continue }
      memos[memo.memoID]?.completion = .uploading
      work.append(.complete(memo.memoID, segmentCount: memo.segmentCount))
      capacity -= 1
    }

    let due = entries.values.filter {
      isCreated($0.key.memoID) && isDue($0.state, now: now) && !withheldSegments.contains($0.key)
    }
    .sorted { $0.sequence < $1.sequence }
    for entry in due.prefix(capacity) {
      entries[entry.key]?.state = .uploading
      work.append(.upload(entry.segment))
    }
    return work
  }

  /// The dispatched work could not be saved, so it was not sent: every transfer still marked in flight goes back to pending,
  /// and a create gets its `createMayHaveLanded` back as it was. The next dispatch hands it out again.
  public mutating func revertDispatch(_ work: [OutboxWork]) {
    for item in work {
      switch item {
      case .create(let sent):
        guard items[sent.memoID]?.create == .uploading else { continue }
        items[sent.memoID]?.create = .pending
        items[sent.memoID]?.createMayHaveLanded = flagBeforeDispatch[sent.memoID] ?? false
        flagBeforeDispatch[sent.memoID] = nil
      case .upload(let segment):
        let key = SegmentKey(memoID: segment.memoID, index: segment.index)
        if entries[key]?.state == .uploading { entries[key]?.state = .pending }
      case .complete(let memoID, _):
        if memos[memoID]?.completion == .uploading { memos[memoID]?.completion = .pending }
      case .delete(let memoID):
        if deletions[memoID]?.state == .uploading { deletions[memoID]?.state = .pending }
      }
    }
  }

  public mutating func uploadSucceeded(_ key: SegmentKey) {
    entries[key]?.state = .uploaded
    items[key.memoID]?.lastError = nil
  }

  public mutating func uploadFailed(
    _ key: SegmentKey, now: Date, permanent: Bool = false, transient: Bool = false, reason: String? = nil
  ) {
    guard var entry = entries[key] else { return }
    entry.attempts += 1
    entry.state = failedState(attempts: entry.attempts, now: now, permanent: permanent, transient: transient)
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

  public mutating func completeFailed(
    _ memoID: MemoID, now: Date, permanent: Bool = false, transient: Bool = false, reason: String? = nil
  ) {
    guard var memo = memos[memoID] else { return }
    memo.attempts += 1
    memo.completion = failedState(attempts: memo.attempts, now: now, permanent: permanent, transient: transient)
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
      + items.values.compactMap { Self.retryAt($0.create) } + deletions.values.compactMap { Self.retryAt($0.state) }
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
    flagBeforeDispatch[memoID] = nil
    withheld.remove(memoID)
    withheldSegments = withheldSegments.filter { $0.memoID != memoID }
    entries = entries.filter { $0.key.memoID != memoID }
  }

  private func failedState(attempts: Int, now: Date, permanent: Bool, transient: Bool) -> OutboxState {
    if permanent || (!transient && attempts >= policy.maxAttempts) { return .stalled }
    return .failed(retryAt: now.addingTimeInterval(policy.delay(forAttempt: attempts)))
  }

  private static func retryAt(_ state: OutboxState) -> Date? {
    guard case .failed(let date) = state else { return nil }
    return date
  }

  private static func isBackedOff(_ state: OutboxState) -> Bool {
    if case .failed = state { true } else { false }
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
    guard !withheld.contains(item.memoID) else { return false }
    return switch item.kind {
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
