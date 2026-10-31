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
    case deletion(MemoID)

    var memoID: MemoID {
      switch self {
      case .creation(let id), .completion(let id), .deletion(let id): id
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
  /// Transfers handed out by `dispatch` whose state is being saved: counted against the concurrency cap until they start.
  private var starting = 0
  private var isFlushing = false
  private var flushWaiters: [(generation: Int, continuation: CheckedContinuation<Bool, Never>)] = []
  /// Every `persist()` call takes the next number; a save carries the highest number requested when its snapshot was taken,
  /// so a call knows its own change is on disk when `savedThrough` has reached its number.
  private var requested = 0
  private var savedThrough = 0
  private var isDirty = false
  /// Segments held back from upload, with the number of the `persist()` call that will carry them.
  private var unsavedSegments: [SegmentKey: Int] = [:]
  private var lastSaveError: String?
  private var saveRetry: Task<Void, Never>?
  private let policy: OutboxPolicy
  /// Segment files no queue entry needs any more. Deleted once a save that no longer lists them has landed: if the write
  /// fails, the record on disk still names them and a relaunch needs them.
  private var obsoleteFiles: [(url: URL, generation: Int)] = []
  private var isShutDown = false
  private var sweptStrays: [URL] = []
  private var strayStore: (any SegmentFileStore)?
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
    self.policy = policy
    self.store = store
    self.uploader = uploader
    self.clock = clock
    machine = OutboxStateMachine(record: try await store.load(), policy: policy)
  }

  // MARK: SegmentOutbox

  public func enqueue(_ segment: ClosedSegment) async {
    // Withheld from upload until a save that carries it has landed (`persist()` releases it): a segment the server has but
    // the queue file does not know is lost to a crash, and its file is orphaned. A failed save is retried on a timer and
    // shows in `saveFailure()`.
    guard machine.enqueue(segment, withheld: true) else { return }
    unsavedSegments[SegmentKey(memoID: segment.memoID, index: segment.index)] = requested + 1
    await persist()
    await resume()
  }

  /// A finished take whose record could not be saved is recoverable (a relaunch finishes it with the segments on disk), so
  /// its `complete` is not held; the save is retried and the failure shown like any other.
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
    // Withheld from dispatch while the save is out: another call can run `resume()` at the suspension, and the server must
    // not create a memo the caller is about to be told the queue refused.
    guard machine.enqueueItem(item, withheld: true) else { return false }
    guard await persist() else {
      // No save that carries this item landed. Take it out and say so on disk too, in case another caller's save wrote it
      // between the failure and now: an item the caller was told was refused must not come back after a relaunch.
      machine.withdrawItem(item.memoID)
      await persist()
      throw OutboxError.notSaved
    }
    machine.release(item.memoID)
    await resume()
    return true
  }

  /// Sends a failed or stalled item again now, with a fresh attempt count.
  public func retryNow(_ memoID: MemoID) async {
    guard machine.retryNow(memoID) else { return }
    await persist()
    await resume()
  }

  /// Tries every transfer that is waiting out a backoff now (the connection changed, the app came to the front), without
  /// touching its attempt count. Stalled transfers wait for `retryNow`.
  public func retryBackedOff() async {
    if machine.retryBackedOff() { await persist() }
    await resume()
  }

  /// Drops the item and everything queued for it, and deletes its segment files. A transfer already on the wire is
  /// cancelled. A take whose memo the server may already have is deleted there too: the `DELETE` is queued like any other
  /// transfer (it survives a relaunch and is retried until the server answers) and goes out after a `create` that was on
  /// the wire has ended, so it cannot overtake the request that makes the memo. A late segment or `complete` for that memo
  /// is a 409 the server gives; nothing of the memo is queued any more, so it is dropped, never a stall.
  public func discard(_ memoID: MemoID) async {
    let deleteOnServer = machine.needsServerDelete(memoID)
    let creating = inFlight[.creation(memoID)]
    for (id, task) in inFlight where id.memoID == memoID { task.cancel() }
    retire(machine.discard(memoID, deleteOnServer: deleteOnServer))
    unsavedSegments = unsavedSegments.filter { $0.key.memoID != memoID }
    await persist()
    await creating?.value
    machine.releaseDeletion(memoID)
    await resume()
  }

  /// The user stops trying to remove a discarded take's memo from the server (its `DELETE` stalled and stays in the queue until
  /// they do, or until a retry succeeds).
  public func abandonDeletion(_ memoID: MemoID) async {
    inFlight[.deletion(memoID)]?.cancel()
    machine.abandonDeletion(memoID)
    await persist()
    await resume()
  }

  /// The memo left the queue because it was discarded in this run, not because the server has it complete.
  public func wasDiscarded(_ memoID: MemoID) -> Bool { machine.wasDiscarded(memoID) }

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
    guard !isShutDown else { return }  // shut down while the clock was answering
    let work = machine.dispatch(now: now, inFlight: inFlight.count + starting)
    if !work.isEmpty {
      // The dispatched state is saved before anything goes out: a kill with a create on the wire must leave
      // `createMayHaveLanded` on disk, or a later discard would not delete a memo the server may have.
      starting += work.count
      let saved = await persist()
      starting -= work.count
      if saved {
        for item in work where isStillDispatched(item) && !isShutDown { start(item) }
      } else {
        // Nothing went out on a state the disk does not have; the save is retried on its timer, which resumes the work.
        machine.revertDispatch(work)
      }
    }
    scheduleWake(after: now)
    resolveIdleWaiters()
  }

  /// The save is a suspension: the item may have been discarded, retried or finished meanwhile, in which case it is not
  /// sent (a create for a discarded take would land after its `DELETE`).
  private func isStillDispatched(_ work: OutboxWork) -> Bool {
    switch work {
    case .create(let item): machine.items[item.memoID]?.create == .uploading
    case .upload(let segment):
      machine.entries[SegmentKey(memoID: segment.memoID, index: segment.index)]?.state == .uploading
    case .complete(let memoID, _): machine.memos[memoID]?.completion == .uploading
    case .delete(let memoID): machine.deletions[memoID]?.state == .uploading
    }
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
    saveRetry?.cancel()
    saveRetry = nil
    wakeTask?.cancel()
    wakeTask = nil
    wakeDeadline = nil
    for task in inFlight.values { task.cancel() }
    for observer in observers.values { observer.finish() }
    observers = [:]
  }

  /// Why the last save failed, or `nil` when the queue on disk is current.
  public func saveFailure() -> String? { lastSaveError }

  /// Current queue, oldest first.
  public func entries() -> [OutboxEntry] { machine.record.entries }
  public func memos() -> [OutboxMemo] { machine.record.memos }
  public func items() -> [OutboxItem] { machine.liveItems }

  // MARK: Startup sweep (`OutboxSweep.swift`)

  /// The segment files the queue still needs: those of its entries, and those waiting for the save that retires them.
  func segmentFileNames() -> Set<String> {
    Set(machine.entries.values.map(\.segment.fileURL.lastPathComponent)).union(
      obsoleteFiles.map(\.url.lastPathComponent))
  }

  /// Takes in a segment file the saved queue never named (see `OutboxStateMachine.adopt`), held back until the next save.
  func adoptSwept(_ segment: ClosedSegment) -> Bool {
    guard machine.adopt(segment) else { return false }
    unsavedSegments[SegmentKey(memoID: segment.memoID, index: segment.index)] = requested + 1
    return true
  }

  /// What the last sweep could neither attach nor move (`SweepReport.stuck`), and the store that can describe it.
  func noteStrays(_ urls: [URL], in files: any SegmentFileStore) {
    sweptStrays = urls
    strayStore = files
  }

  /// The files the last startup sweep left in the capture directory because it could not move them (a full disk, a read-only
  /// volume), those still there, for Settings to list. They are tried again at the next launch.
  public func strayFiles() async -> [SetAsideFile] {
    guard let strayStore, !sweptStrays.isEmpty else { return [] }
    return await strayStore.describe(sweptStrays)
  }

  /// The sweep is over: a take that had no segment and has no file that could still hold its audio is dropped from the saved
  /// queue; one whose audio could not be ruled out stays in it (`keeping`) for the next launch.
  func settleEmptyTakes(keeping: Set<MemoID>) async {
    if machine.settleEmptyTakes(keeping: keeping) { await persist() }
  }

  /// Holds back the `complete` of takes whose end may sit in a shadow the sweep could not recover.
  func holdCompletions(of memoIDs: Set<MemoID>) {
    for id in memoIDs {
      machine.holdCompletion(
        id, reason: "A recording of this take could not be recovered yet. It is tried again at the next launch.")
    }
  }

  /// Without a capture directory to sweep (fakes) nothing can bring an empty take back: they are dropped.
  public func settleUnrecoveredTakes() async { await settleEmptyTakes(keeping: []) }

  /// The queue files earlier resets set aside (they may name segment files the sweep must leave alone).
  func setAsideQueueFiles() async -> [URL] { await store.quarantined() }

  // MARK: Internals

  private var isIdle: Bool { inFlight.isEmpty && finishing == 0 && starting == 0 && !isFlushing }

  private func start(_ work: OutboxWork) {
    let id: TransferID
    switch work {
    case .create(let item): id = .creation(item.memoID)
    case .upload(let segment): id = .segment(SegmentKey(memoID: segment.memoID, index: segment.index))
    case .complete(let memoID, _): id = .completion(memoID)
    case .delete(let memoID): id = .deletion(memoID)
    }
    // Owned by `inFlight` and cancelled by `shutdown()`.
    inFlight[id] = Task { [uploader] in
      let outcome: Result<Void, any Error>
      do {
        switch work {
        case .create(let item): try await uploader.create(item)
        case .upload(let segment): try await uploader.upload(segment)
        case .complete(let memoID, let count): try await uploader.complete(memoID: memoID, segmentCount: count)
        case .delete(let memoID): try await uploader.delete(memoID: memoID)
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
      machine.createFailed(
        memoID, now: now, permanent: Self.isPermanent(error), transient: Self.isTransient(error),
        reason: Self.reason(error))
    case (.segment(let key), .success): machine.uploadSucceeded(key)
    case (.segment(let key), .failure) where cancelled: machine.uploadCancelled(key)
    case (.segment(let key), .failure(let error)):
      Log.outbox.error("upload failed: \(String(describing: error), privacy: .public)")
      machine.uploadFailed(
        key, now: now, permanent: Self.isPermanent(error), transient: Self.isTransient(error),
        reason: Self.reason(error))
    case (.completion(let memoID), .success):
      // The server acknowledged the memo: its segment files are no longer needed, once the state that says so is saved.
      if deletesFilesWhenDone {
        retire(machine.entries.values.filter { $0.key.memoID == memoID }.map(\.segment.fileURL))
      }
      machine.completeSucceeded(memoID)
    case (.completion(let memoID), .failure) where cancelled: machine.completeCancelled(memoID)
    case (.completion(let memoID), .failure(let error as MissingSegmentsError)):
      Log.outbox.error("complete refused, the server lacks \(error.indices.count) segments: sending them again")
      machine.completeMissingSegments(memoID, missing: error.indices, now: now, reason: error.message)
    case (.completion(let memoID), .failure(let error)):
      Log.outbox.error("complete failed: \(String(describing: error), privacy: .public)")
      machine.completeFailed(
        memoID, now: now, permanent: Self.isPermanent(error), transient: Self.isTransient(error),
        reason: Self.reason(error))
    case (.deletion(let memoID), .success): machine.deleteSucceeded(memoID)
    case (.deletion(let memoID), .failure) where cancelled: machine.deleteCancelled(memoID)
    case (.deletion(let memoID), .failure(let error)):
      Log.outbox.error("delete failed: \(String(describing: error), privacy: .public)")
      machine.deleteFailed(
        memoID, now: now, permanent: Self.isPermanent(error), transient: Self.isTransient(error),
        reason: Self.reason(error))
    }
    await persist()
    await resume()
    finishing -= 1
    resolveIdleWaiters()
  }

  /// Called right before the `persist()` that records why the files are obsolete, so that call's number is the next one.
  /// Saves again on a growing delay until a save lands, then lets whatever it released go out. One timer at a time.
  private func retrySave() {
    guard saveRetry == nil, !isShutDown else { return }
    // Owned by `saveRetry`; ends with the first save that lands and is cancelled by `shutdown()`.
    saveRetry = Task { [clock, policy] in
      var attempt = 0
      while !Task.isCancelled {
        attempt += 1
        let wake = (await clock.now()).addingTimeInterval(policy.delay(forAttempt: attempt))
        do { try await clock.sleep(until: wake) } catch { break }
        if await self.persist() { break }
      }
      await self.saveRetryEnded()
    }
  }

  private func saveRetryEnded() async {
    saveRetry = nil
    await resume()
  }

  private func retire(_ files: [URL]) {
    obsoleteFiles.append(contentsOf: files.map { ($0, requested + 1) })
  }

  private static func isPermanent(_ error: any Error) -> Bool { error is PermanentTransferError }

  private static func isTransient(_ error: any Error) -> Bool { error is TransientTransferError }

  private static func reason(_ error: any Error) -> String {
    if let permanent = error as? PermanentTransferError { return permanent.message }
    if let transient = error as? TransientTransferError { return transient.message }
    return String(describing: error)
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

  /// Saves the latest state. Concurrent callers coalesce into one flush loop, so an older snapshot can never overwrite a
  /// newer one; every caller returns after the latest state is saved. The answer is whether a save that was started after
  /// this call (so it carries this call's change) landed: a failure of a later save does not undo an earlier one.
  @discardableResult
  func persist() async -> Bool {
    requested += 1
    let mine = requested
    isDirty = true
    if isFlushing {
      return await withCheckedContinuation { flushWaiters.append((mine, $0)) }
    }
    isFlushing = true
    while isDirty {
      isDirty = false
      let generation = requested
      do {
        try await store.save(machine.record)
        savedThrough = max(savedThrough, generation)
        lastSaveError = nil
      } catch {
        Log.outbox.error("outbox save failed: \(String(describing: error), privacy: .public)")
        lastSaveError = String(describing: error)
      }
    }
    isFlushing = false
    for (key, generation) in unsavedSegments where generation <= savedThrough {
      machine.release(key)
      unsavedSegments[key] = nil
    }
    if lastSaveError != nil { retrySave() }
    let (due, later) = (
      obsoleteFiles.filter { $0.generation <= savedThrough }, obsoleteFiles.filter { $0.generation > savedThrough }
    )
    for file in due { try? FileManager.default.removeItem(at: file.url) }
    obsoleteFiles = later
    for observer in observers.values { observer.yield() }
    let waiters = flushWaiters
    flushWaiters = []
    for waiter in waiters { waiter.continuation.resume(returning: savedThrough >= waiter.generation) }
    resolveIdleWaiters()
    return savedThrough >= mine
  }

  private func resolveIdleWaiters() {
    guard isIdle else { return }
    let waiters = idleWaiters
    idleWaiters = []
    for waiter in waiters { waiter.resume() }
  }
}
