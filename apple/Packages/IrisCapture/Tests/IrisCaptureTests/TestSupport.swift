import Foundation

@testable import IrisCapture

func memo(_ n: UInt8) -> MemoID {
  MemoID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n))
}

func segment(_ memoID: MemoID, _ index: Int, duration: TimeInterval = 10) -> ClosedSegment {
  ClosedSegment(
    memoID: memoID, index: index, fileURL: URL(fileURLWithPath: "/tmp/iris-test/\(index).m4a"),
    byteCount: 1_000, duration: duration)
}

func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appending(path: "iris-capture-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

struct UploadFailure: Error {}

/// A scriptable `SegmentUploader` fake: scripted failures, optional holding of uploads, ordered log.
actor TestUploader: SegmentUploader {
  struct CompleteCall: Equatable {
    let memoID: MemoID
    let segmentCount: Int
  }

  private(set) var attempts: [SegmentKey: Int] = [:]
  private(set) var created: [OutboxItem] = []
  private(set) var createAttempts = 0
  private(set) var uploaded: [SegmentKey] = []
  private(set) var completed: [CompleteCall] = []
  private(set) var deleted: [MemoID] = []
  private(set) var deleteAttempts = 0
  private(set) var maxInFlight = 0
  private(set) var started = 0
  /// "upload" / "complete" in call order, to assert gating.
  private(set) var log: [String] = []

  private var failuresLeft: [SegmentKey: Int] = [:]
  private var closedKeys: Set<SegmentKey> = []
  private var completeFailuresLeft = 0
  private var missingScripts: [[Int]] = []
  private var createFailuresLeft = 0
  private var deleteFailuresLeft = 0
  private var deletesArePermanent = false
  private var createsArePermanent = false
  private var inFlight = 0
  private var isHolding = false
  private var holdsCreates = false
  private var createWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var held: [CheckedContinuation<Void, Never>] = []
  private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var attemptWaiters: [(key: SegmentKey, count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  func failNext(_ times: Int, for key: SegmentKey) { failuresLeft[key] = times }
  func failNextCompletes(_ times: Int) { completeFailuresLeft = times }

  /// The server closed this segment's memo without it: every upload of the key throws `LateTailError`.
  func closeMemo(for key: SegmentKey) { closedKeys.insert(key) }

  /// The next `complete` answers that the server lacks these segments (422 `missing_segments`), one script per call.
  func failNextComplete(missing scripts: [[Int]]) { missingScripts = scripts }

  /// The next `times` creates throw: `PermanentTransferError` when `permanent`, else a plain error that is retried.
  func failNextCreates(_ times: Int, permanent: Bool = false) {
    createFailuresLeft = times
    createsArePermanent = permanent
  }

  /// The next `times` deletes throw: `PermanentTransferError` when `permanent`, else a `TransientTransferError`.
  func failNextDeletes(_ times: Int, permanent: Bool = false) {
    deleteFailuresLeft = times
    deletesArePermanent = permanent
  }
  func hold() { isHolding = true }
  /// Creates wait (after counting as attempted) until `releaseAll()`: a request on the wire whose answer has not come.
  func holdCreates() { holdsCreates = true }

  func waitUntilCreateAttempts(_ count: Int) async {
    guard createAttempts < count else { return }
    await withCheckedContinuation { createWaiters.append((count, $0)) }
  }

  func releaseAll() {
    isHolding = false
    holdsCreates = false
    let continuations = held
    held = []
    for continuation in continuations { continuation.resume() }
  }

  func waitUntilStarted(_ count: Int) async {
    guard started < count else { return }
    await withCheckedContinuation { startWaiters.append((count, $0)) }
  }

  func waitUntilAttempts(_ count: Int, for key: SegmentKey) async {
    guard attempts[key, default: 0] < count else { return }
    await withCheckedContinuation { attemptWaiters.append((key, count, $0)) }
  }

  func create(_ item: OutboxItem) async throws {
    createAttempts += 1
    let ready = createWaiters.filter { $0.count <= createAttempts }
    createWaiters.removeAll { $0.count <= createAttempts }
    for waiter in ready { waiter.continuation.resume() }
    if holdsCreates { await withCheckedContinuation { held.append($0) } }
    if createFailuresLeft > 0 {
      createFailuresLeft -= 1
      if createsArePermanent { throw PermanentTransferError("refused") }
      throw UploadFailure()
    }
    created.append(item)
    log.append("create")
  }

  func upload(_ segment: ClosedSegment) async throws {
    let key = SegmentKey(memoID: segment.memoID, index: segment.index)
    attempts[key, default: 0] += 1
    started += 1
    inFlight += 1
    maxInFlight = max(maxInFlight, inFlight)
    resolveWaiters()
    if isHolding { await withCheckedContinuation { held.append($0) } }
    inFlight -= 1
    if closedKeys.contains(key) { throw LateTailError("no longer receiving") }
    if failuresLeft[key, default: 0] > 0 {
      failuresLeft[key, default: 0] -= 1
      throw UploadFailure()
    }
    uploaded.append(key)
    log.append("upload")
  }

  func complete(memoID: MemoID, segmentCount: Int) async throws {
    if !missingScripts.isEmpty {
      throw MissingSegmentsError(indices: missingScripts.removeFirst(), message: "segments missing")
    }
    if completeFailuresLeft > 0 {
      completeFailuresLeft -= 1
      throw UploadFailure()
    }
    completed.append(CompleteCall(memoID: memoID, segmentCount: segmentCount))
    log.append("complete")
  }

  func delete(memoID: MemoID) async throws {
    deleteAttempts += 1
    if deleteFailuresLeft > 0 {
      deleteFailuresLeft -= 1
      if deletesArePermanent { throw PermanentTransferError("not deletable") }
      throw TransientTransferError("offline")
    }
    deleted.append(memoID)
    log.append("delete")
  }

  private func resolveWaiters() {
    let ready = startWaiters.filter { started >= $0.count }
    startWaiters.removeAll { started >= $0.count }
    for waiter in ready { waiter.continuation.resume() }
    let attemptsReady = attemptWaiters.filter { attempts[$0.key, default: 0] >= $0.count }
    attemptWaiters.removeAll { attempts[$0.key, default: 0] >= $0.count }
    for waiter in attemptsReady { waiter.continuation.resume() }
  }
}

struct OutboxHarness {
  let outbox: Outbox
  let store: InMemoryOutboxStore
  let uploader: TestUploader
  let clock: ManualClock

  init(
    record: OutboxRecord = OutboxRecord(),
    policy: OutboxPolicy = OutboxPolicy(jitter: { 0 }),
    clock: ManualClock = ManualClock(),
    uploader: TestUploader = TestUploader(),
    deletesFilesWhenDone: Bool = true,
    serverKey: @escaping @Sendable () -> String? = { nil }
  ) async throws {
    store = InMemoryOutboxStore(record: record)
    self.uploader = uploader
    self.clock = clock
    outbox = try await Outbox(
      store: store, uploader: uploader, clock: clock, policy: policy, deletesFilesWhenDone: deletesFilesWhenDone,
      serverKey: serverKey)
  }
}

func textItem(
  _ id: MemoID, text: String = "hello", mode: String = "auto", threadID: String? = nil,
  queuedAt: Date = Date(timeIntervalSince1970: 1_000_000)
) -> OutboxItem {
  OutboxItem(
    memoID: id, kind: .text(text), mode: mode, threadID: threadID, startedAt: queuedAt, queuedAt: queuedAt, title: text)
}

func voiceItem(_ id: MemoID, queuedAt: Date = Date(timeIntervalSince1970: 1_000_000)) -> OutboxItem {
  OutboxItem(
    memoID: id, kind: .voice, mode: "auto", startedAt: queuedAt, queuedAt: queuedAt, title: "Voice memo")
}
