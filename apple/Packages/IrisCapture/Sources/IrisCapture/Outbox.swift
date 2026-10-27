import Foundation

/// The persistent upload queue: one entry per (memo, segment), at most
/// `OutboxPolicy.maxConcurrentUploads` transfers in flight, retries with exponential backoff.
///
/// All I/O goes through injected ports (`OutboxStore`, `SegmentUploader`, `CaptureClock`); the decisions
/// live in `OutboxStateMachine`. Call `shutdown()` when done: it cancels the in-flight transfers and
/// the retry timer this actor owns.
public actor Outbox: SegmentOutbox {
  private enum TransferID: Hashable {
    case segment(SegmentKey)
    case completion(MemoID)
  }

  private var machine: OutboxStateMachine
  private let store: any OutboxStore
  private let uploader: any SegmentUploader
  private let clock: any CaptureClock

  private var inFlight: [TransferID: Task<Void, Never>] = [:]
  private var wakeTask: Task<Void, Never>?
  private var wakeDeadline: Date?
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private var finishing = 0
  private var isFlushing = false
  private var flushWaiters: [CheckedContinuation<Void, Never>] = []
  private var isDirty = false
  private var isShutDown = false

  /// Loads the persisted queue. Entries that were uploading when the app died return to pending.
  /// Call `resume()` to continue sending.
  public init(
    store: any OutboxStore,
    uploader: any SegmentUploader,
    clock: any CaptureClock,
    policy: OutboxPolicy = OutboxPolicy()
  ) async throws {
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
  }

  /// Current queue, oldest first.
  public func entries() -> [OutboxEntry] { machine.record.entries }
  public func memos() -> [OutboxMemo] { machine.record.memos }

  // MARK: Internals

  private var isIdle: Bool { inFlight.isEmpty && finishing == 0 && !isFlushing }

  private func start(_ work: OutboxWork) {
    let id: TransferID
    switch work {
    case .upload(let segment): id = .segment(SegmentKey(memoID: segment.memoID, index: segment.index))
    case .complete(let memoID, _): id = .completion(memoID)
    }
    // Owned by `inFlight` and cancelled by `shutdown()`.
    inFlight[id] = Task { [uploader] in
      let outcome: Result<Void, any Error>
      do {
        switch work {
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
    case (.segment(let key), .success): machine.uploadSucceeded(key)
    case (.segment(let key), .failure) where cancelled: machine.uploadCancelled(key)
    case (.segment(let key), .failure(let error)):
      Log.outbox.error("upload failed, will retry: \(String(describing: error), privacy: .public)")
      machine.uploadFailed(key, now: now)
    case (.completion(let memoID), .success): machine.completeSucceeded(memoID)
    case (.completion(let memoID), .failure) where cancelled: machine.completeCancelled(memoID)
    case (.completion(let memoID), .failure(let error)):
      Log.outbox.error("complete failed, will retry: \(String(describing: error), privacy: .public)")
      machine.completeFailed(memoID, now: now)
    }
    await persist()
    await resume()
    finishing -= 1
    resolveIdleWaiters()
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
  /// can never overwrite a newer one; every caller returns after the latest state is saved.
  private func persist() async {
    isDirty = true
    if isFlushing {
      await withCheckedContinuation { flushWaiters.append($0) }
      return
    }
    isFlushing = true
    while isDirty {
      isDirty = false
      do {
        try await store.save(machine.record)
      } catch {
        Log.outbox.error("outbox save failed: \(String(describing: error), privacy: .public)")
      }
    }
    isFlushing = false
    let waiters = flushWaiters
    flushWaiters = []
    for waiter in waiters { waiter.resume() }
    resolveIdleWaiters()
  }

  private func resolveIdleWaiters() {
    guard isIdle else { return }
    let waiters = idleWaiters
    idleWaiters = []
    for waiter in waiters { waiter.resume() }
  }
}
