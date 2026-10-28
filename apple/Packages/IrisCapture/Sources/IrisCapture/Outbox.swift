import Foundation

/// The persistent upload queue: one entry per (memo, segment), at most
/// `OutboxPolicy.maxConcurrentUploads` transfers in flight, retries with exponential backoff.
///
/// All I/O goes through injected ports (`OutboxStore`, `SegmentUploader`, `CaptureClock`); the decisions
/// live in `OutboxStateMachine`. Call `shutdown()` when done: it cancels the in-flight transfers and
/// the retry timer this actor owns.
public actor Outbox: SegmentOutbox {
  private enum TransferID: Hashable {
    case creation(MemoID)
    case segment(SegmentKey)
    case completion(MemoID)

    var memoID: MemoID {
      switch self {
      case .creation(let id), .completion(let id): id
      case .segment(let key): key.memoID
      }
    }
  }

  private var machine: OutboxStateMachine
  private let store: any OutboxStore
  private let uploader: any SegmentUploader
  private let clock: any CaptureClock
  private let deletesFilesWhenDone: Bool

  private var inFlight: [TransferID: Task<Void, Never>] = [:]
  private var wakeTask: Task<Void, Never>?
  private var wakeDeadline: Date?
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private var finishing = 0
  private var isFlushing = false
  private var flushWaiters: [CheckedContinuation<Bool, Never>] = []
  private var isDirty = false
  private var isShutDown = false
  private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

  /// - Parameter deletesFilesWhenDone: Remove a memo's segment files once `complete` succeeded (tests that read them turn it off).
  /// Loads the persisted queue. Entries that were uploading when the app died return to pending.
  /// Call `resume()` to continue sending.
  public init(
    store: any OutboxStore,
    uploader: any SegmentUploader,
    clock: any CaptureClock,
    policy: OutboxPolicy = OutboxPolicy(),
    deletesFilesWhenDone: Bool = true
  ) async throws {
    self.deletesFilesWhenDone = deletesFilesWhenDone
    self.store = store
    self.uploader = uploader
    self.clock = clock
    machine = OutboxStateMachine(record: try await store.load(), policy: policy)
  }

  // MARK: SegmentOutbox

  public func enqueue(_ segment: ClosedSegment) async {
    guard machine.enqueue(segment) else { return }
    await persist()
    await resume()
  }

  public func finishMemo(_ memoID: MemoID, segmentCount: Int) async {
    machine.finishMemo(memoID, segmentCount: segmentCount)
    await persist()
    await resume()
  }

  // MARK: Items

  /// Queues a whole memo or message and starts sending it. `false` when the memo id is already queued or done.
  /// Throws `OutboxError.notSaved` when the queue could not be written (a full disk, an I/O error): the item is taken
  /// back out, so nothing is "queued" that a kill would lose, and the caller keeps what the user typed.
  @discardableResult
  public func enqueueItem(_ item: OutboxItem) async throws -> Bool {
    guard machine.enqueueItem(item) else { return false }
    guard await persist() else {
      machine.withdrawItem(item.memoID)
      throw OutboxError.notSaved
    }
    await resume()
    return true
  }

  /// Sends a failed or stalled item again now, with a fresh attempt count.
  public func retryNow(_ memoID: MemoID) async {
    guard machine.retryNow(memoID) else { return }
    await persist()
    await resume()
  }

  /// Drops the item and everything queued for it, and deletes its segment files. A transfer already on the wire is
  /// cancelled; the server keeps whatever it already has.
  public func discard(_ memoID: MemoID) async {
    for (id, task) in inFlight where id.memoID == memoID { task.cancel() }
    for file in machine.discard(memoID) { try? FileManager.default.removeItem(at: file) }
    await persist()
    await resume()
  }

  /// The queue for the UI, oldest first.
  public func queue() -> [OutboxQueueItem] { machine.queue() }

  /// A stream that yields once per saved change (queue or state), for as long as the consumer iterates.
  public func changes() -> AsyncStream<Void> {
    let id = UUID()
    let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    observers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      guard let self else { return }
      Task { await self.removeObserver(id) }
    }
    return stream
  }

  private func removeObserver(_ id: UUID) {
    observers[id] = nil
  }

  // MARK: Driving

  /// Starts every transfer that is due and arms the retry timer.
  public func resume() async {
    guard !isShutDown else { return }
    let now = await clock.now()
    let work = machine.dispatch(now: now, inFlight: inFlight.count)
    for item in work { start(item) }
    if !work.isEmpty { await persist() }
    scheduleWake(after: now)
    resolveIdleWaiters()
  }

  /// Dispatches due work, then returns once no transfer is in flight and the store is flushed.
  /// Transfers waiting for a retry deadline do not hold it up.
  public func settled() async {
    await resume()
    guard !isIdle else { return }
    await withCheckedContinuation { idleWaiters.append($0) }
  }

  public func shutdown() {
    isShutDown = true
    wakeTask?.cancel()
    wakeTask = nil
    wakeDeadline = nil
    for task in inFlight.values { task.cancel() }
    for observer in observers.values { observer.finish() }
    observers = [:]
  }

  /// Current queue, oldest first.
  public func entries() -> [OutboxEntry] { machine.record.entries }
  public func memos() -> [OutboxMemo] { machine.record.memos }
  public func items() -> [OutboxItem] { machine.record.items }

  // MARK: Internals

  private var isIdle: Bool { inFlight.isEmpty && finishing == 0 && !isFlushing }

  private func start(_ work: OutboxWork) {
    let id: TransferID
    switch work {
    case .create(let item): id = .creation(item.memoID)
    case .upload(let segment): id = .segment(SegmentKey(memoID: segment.memoID, index: segment.index))
    case .complete(let memoID, _): id = .completion(memoID)
    }
    // Owned by `inFlight` and cancelled by `shutdown()`.
    inFlight[id] = Task { [uploader] in
      let outcome: Result<Void, any Error>
      do {
        switch work {
        case .create(let item): try await uploader.create(item)
        case .upload(let segment): try await uploader.upload(segment)
        case .complete(let memoID, let count): try await uploader.complete(memoID: memoID, segmentCount: count)
        }
        outcome = .success(())
      } catch {
        outcome = .failure(error)
      }
      await self.finished(id, outcome)
    }
  }

  private func finished(_ id: TransferID, _ outcome: Result<Void, any Error>) async {
    // Counted so `settled()` does not return between this transfer ending and the follow-up dispatch.
    finishing += 1
    let now = await clock.now()
    inFlight[id] = nil
    let cancelled = Task.isCancelled || isShutDown
    switch (id, outcome) {
    case (.creation(let memoID), .success): machine.createSucceeded(memoID)
    case (.creation(let memoID), .failure) where cancelled: machine.createCancelled(memoID)
    case (.creation(let memoID), .failure(let error)):
      Log.outbox.error("create failed: \(String(describing: error), privacy: .public)")
      machine.createFailed(memoID, now: now, permanent: Self.isPermanent(error), reason: Self.reason(error))
    case (.segment(let key), .success): machine.uploadSucceeded(key)
    case (.segment(let key), .failure) where cancelled: machine.uploadCancelled(key)
    case (.segment(let key), .failure(let error)):
      Log.outbox.error("upload failed: \(String(describing: error), privacy: .public)")
      machine.uploadFailed(key, now: now, permanent: Self.isPermanent(error), reason: Self.reason(error))
    case (.completion(let memoID), .success):
      // The server acknowledged the memo: its segment files are no longer needed.
      if deletesFilesWhenDone {
        for entry in machine.entries.values where entry.key.memoID == memoID {
          try? FileManager.default.removeItem(at: entry.segment.fileURL)
        }
      }
      machine.completeSucceeded(memoID)
    case (.completion(let memoID), .failure) where cancelled: machine.completeCancelled(memoID)
    case (.completion(let memoID), .failure(let error)):
      Log.outbox.error("complete failed: \(String(describing: error), privacy: .public)")
      machine.completeFailed(memoID, now: now, permanent: Self.isPermanent(error), reason: Self.reason(error))
    }
    await persist()
    await resume()
    finishing -= 1
    resolveIdleWaiters()
  }

  private static func isPermanent(_ error: any Error) -> Bool { error is PermanentTransferError }

  private static func reason(_ error: any Error) -> String {
    (error as? PermanentTransferError)?.message ?? String(describing: error)
  }

  private func scheduleWake(after now: Date) {
    let deadline = machine.nextWake(after: now)
    guard deadline != wakeDeadline else { return }
    wakeTask?.cancel()
    wakeDeadline = deadline
    guard let deadline else {
      wakeTask = nil
      return
    }
    // Owned by `wakeTask`; replaced here and cancelled by `shutdown()`.
    wakeTask = Task { [clock] in
      do { try await clock.sleep(until: deadline) } catch { return }
      await self.wakeFired(deadline)
    }
  }

  private func wakeFired(_ deadline: Date) async {
    if wakeDeadline == deadline { wakeDeadline = nil }
    await resume()
  }

  /// Returns once the latest state is saved.
  public func flush() async {
    await persist()
  }

  /// Saves the latest state. Concurrent callers coalesce into one flush loop, so an older snapshot
  /// can never overwrite a newer one; every caller returns after the latest state is saved, with whether the last
  /// write landed.
  @discardableResult
  private func persist() async -> Bool {
    isDirty = true
    if isFlushing {
      return await withCheckedContinuation { flushWaiters.append($0) }
    }
    isFlushing = true
    var saved = true
    while isDirty {
      isDirty = false
      do {
        try await store.save(machine.record)
        saved = true
      } catch {
        saved = false
        Log.outbox.error("outbox save failed: \(String(describing: error), privacy: .public)")
      }
    }
    isFlushing = false
    for observer in observers.values { observer.yield() }
    let waiters = flushWaiters
    flushWaiters = []
    for waiter in waiters { waiter.resume(returning: saved) }
    resolveIdleWaiters()
    return saved
  }

  private func resolveIdleWaiters() {
    guard isIdle else { return }
    let waiters = idleWaiters
    idleWaiters = []
    for waiter in waiters { waiter.resume() }
  }
}
