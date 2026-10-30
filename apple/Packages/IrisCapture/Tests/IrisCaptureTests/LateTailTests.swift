import Foundation
import Testing

@testable import IrisCapture

/// Wraps `TestUploader`: the listed segments are refused as a late tail (the server closed their memo without them), and
/// creates of `holding` memos wait until `release()`.
private actor LateTailUploader: SegmentUploader {
  let base: TestUploader
  private let late: Set<SegmentKey>
  private let held: Int
  private var holding: Set<MemoID> = []
  private var waiting: [CheckedContinuation<Void, Never>] = []

  /// `held`: the segment count the server completed the take's memo with.
  init(base: TestUploader, late: Set<SegmentKey>, held: Int = 1) {
    self.base = base
    self.late = late
    self.held = held
  }

  func holdCreates(of ids: Set<MemoID>) { holding = ids }

  func release() {
    holding = []
    let continuations = waiting
    waiting = []
    for continuation in continuations { continuation.resume() }
  }

  func create(_ item: OutboxItem) async throws {
    if holding.contains(item.memoID) { await withCheckedContinuation { waiting.append($0) } }
    try await base.create(item)
  }

  func upload(_ segment: ClosedSegment) async throws {
    if late.contains(SegmentKey(memoID: segment.memoID, index: segment.index)) {
      throw LateSegmentError(label: "Late recording", answer: "no longer receiving", serverSegmentCount: held)
    }
    try await base.upload(segment)
  }

  func complete(memoID: MemoID, segmentCount: Int) async throws {
    try await base.complete(memoID: memoID, segmentCount: segmentCount)
  }

  func delete(memoID: MemoID) async throws { try await base.delete(memoID: memoID) }
}

/// A store whose first save that lists `memoID` waits until `open()`: the moment the outbox is suspended in the middle of a
/// diversion.
private actor GatedStore: OutboxStore {
  private let base = InMemoryOutboxStore()
  private let memoID: MemoID
  private var isHeld = false
  private var isDone = false
  private var held: CheckedContinuation<Void, Never>?
  private var arrivals: [CheckedContinuation<Void, Never>] = []

  init(holding memoID: MemoID) { self.memoID = memoID }

  func load() async throws -> OutboxRecord { try await base.load() }

  func save(_ record: OutboxRecord) async throws {
    if !isDone, record.items.contains(where: { $0.memoID == memoID }) {
      isDone = true
      isHeld = true
      for waiter in arrivals { waiter.resume() }
      arrivals = []
      await withCheckedContinuation { held = $0 }
    }
    try await base.save(record)
  }

  func waitUntilHeld() async {
    guard !isHeld else { return }
    await withCheckedContinuation { arrivals.append($0) }
  }

  func open() {
    held?.resume()
    held = nil
  }
}

/// Wave 18 I1: the tail of a take that reaches a memo the server already closed becomes a memo of its own.
struct LateTailTests {
  private let original = memo(1)

  private func files(_ directory: URL, indices: [Int]) throws -> [ClosedSegment] {
    try indices.map { index in
      let url = directory.appending(path: "\(original.uuidString)-\(index).m4a")
      try Data("audio-\(index)".utf8).write(to: url)
      return ClosedSegment(memoID: original, index: index, fileURL: url, byteCount: 7, duration: 10)
    }
  }

  private func outbox(
    _ uploader: LateTailUploader, store: InMemoryOutboxStore = InMemoryOutboxStore()
  ) async throws -> Outbox {
    try await Outbox(store: store, uploader: uploader, clock: ManualClock(), policy: OutboxPolicy(jitter: { 0 }))
  }

  @Test func theTailBecomesItsOwnTranscribeMemoNamedAfterTheTake() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let segments = try files(directory, indices: [0, 1])
    let base = TestUploader()
    let uploader = LateTailUploader(base: base, late: [SegmentKey(memoID: original, index: 1)])
    let outbox = try await outbox(uploader)

    try await outbox.enqueueItem(voiceItem(original))
    for segment in segments { await outbox.enqueue(segment) }
    await outbox.finishMemo(original, segmentCount: 2)
    await outbox.settled()

    let tail = LateTail.memoID(of: original, index: 1)
    let created = await base.created
    #expect(created.map(\.memoID) == [original, tail])
    let item = try #require(created.last)
    #expect(item.mode == "transcribe" && item.kind == .voice && item.threadID == nil)
    #expect(item.title.hasPrefix("Late recording · Voice memo "), "the row names the take: \(item.title)")
    #expect(item.title.hasSuffix(original.uuidString.prefix(8).lowercased()))
    #expect(await base.uploaded.contains(SegmentKey(memoID: tail, index: 0)))
    #expect(await base.completed.contains(.init(memoID: tail, segmentCount: 1)))
    #expect(
      await base.completed.contains(.init(memoID: original, segmentCount: 1)),
      "the take is completed with the count the server holds, so its complete is not refused")
    #expect(await outbox.queue().isEmpty)
    await outbox.shutdown()
  }

  @Test func theAudioOutlivesTheTakesCleanUpUntilTheNewMemoIsCreated() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let segments = try files(directory, indices: [0, 1])
    let tail = LateTail.memoID(of: original, index: 1)
    let base = TestUploader()
    let uploader = LateTailUploader(base: base, late: [SegmentKey(memoID: original, index: 1)])
    await uploader.holdCreates(of: [tail])
    let outbox = try await outbox(uploader)

    try await outbox.enqueueItem(voiceItem(original))
    for segment in segments { await outbox.enqueue(segment) }
    await outbox.finishMemo(original, segmentCount: 2)
    // The take completes and removes its own files while the new memo's create is still on the wire.
    for _ in 0..<500 where await base.completed.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await base.completed.contains(.init(memoID: original, segmentCount: 1)))

    let kept = directory.appending(path: "\(tail.uuidString)-0.m4a")
    #expect(try Data(contentsOf: kept) == Data("audio-1".utf8), "the audio is still there")

    await uploader.release()
    await outbox.settled()
    #expect(await base.completed.contains(.init(memoID: tail, segmentCount: 1)))
    #expect(await outbox.queue().isEmpty)
    await outbox.shutdown()
  }

  @Test func aTailThatWasAlreadyDivertedIsNotMadeTwice() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let segments = try files(directory, indices: [0, 1])
    let tail = LateTail.memoID(of: original, index: 1)
    let base = TestUploader()
    let outbox = try await outbox(LateTailUploader(base: base, late: [SegmentKey(memoID: original, index: 1)]))

    // What an earlier run left behind (it was killed before it marked the original segment): the tail is queued already.
    let tailFile = directory.appending(path: "\(tail.uuidString)-0.m4a")
    try Data("audio-1".utf8).write(to: tailFile)
    try await outbox.enqueueItem(voiceItem(tail))
    await outbox.enqueue(ClosedSegment(memoID: tail, index: 0, fileURL: tailFile, byteCount: 7, duration: 10))
    await outbox.finishMemo(tail, segmentCount: 1)

    try await outbox.enqueueItem(voiceItem(original))
    for segment in segments { await outbox.enqueue(segment) }
    await outbox.finishMemo(original, segmentCount: 2)
    await outbox.settled()

    #expect(await base.created.map(\.memoID).filter { $0 == tail }.count == 1)
    #expect(await base.completed.filter { $0.memoID == tail }.count == 1)
    #expect(await base.completed.contains(.init(memoID: original, segmentCount: 1)))
    #expect(await outbox.queue().isEmpty)
    await outbox.shutdown()
  }

  @Test func aDiscardWhileTheDiversionIsSavingDropsTheDerivedMemoBeforeItCanUpload() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let segments = try files(directory, indices: [0, 1])
    let tail = LateTail.memoID(of: original, index: 1)
    let store = GatedStore(holding: tail)
    let base = TestUploader()
    let uploader = LateTailUploader(base: base, late: [SegmentKey(memoID: original, index: 1)])
    let outbox = try await Outbox(
      store: store, uploader: uploader, clock: ManualClock(), policy: OutboxPolicy(jitter: { 0 }))

    // In a task of its own: once the diversion is saving, every save behind it waits for the gate.
    let queueing = Task {
      try await outbox.enqueueItem(voiceItem(original))
      for segment in segments { await outbox.enqueue(segment) }
      await outbox.finishMemo(original, segmentCount: 2)
    }
    await store.waitUntilHeld()  // the diversion has queued the tail and is saving it

    let discarding = Task { await outbox.discard(original) }
    for _ in 0..<500 where await !outbox.wasDiscarded(original) { try await Task.sleep(for: .milliseconds(10)) }
    await store.open()
    try await queueing.value
    await discarding.value
    await outbox.settled()

    #expect(await base.created.map(\.memoID) == [original], "the derived memo never reached the server")
    #expect(await base.uploaded.allSatisfy { $0.memoID != tail })
    #expect(await outbox.queue().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "\(tail.uuidString)-0.m4a").path))
    await outbox.shutdown()
  }

  @Test func aLinkLeftByAKillBeforeTheItemWasSavedIsReused() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let segments = try files(directory, indices: [0, 1])
    let tail = LateTail.memoID(of: original, index: 1)
    // The earlier run made the link and died before it saved the item.
    try Data("audio-1".utf8).write(to: directory.appending(path: "\(tail.uuidString)-0.m4a"))
    let base = TestUploader()
    let outbox = try await outbox(LateTailUploader(base: base, late: [SegmentKey(memoID: original, index: 1)]))

    try await outbox.enqueueItem(voiceItem(original))
    for segment in segments { await outbox.enqueue(segment) }
    await outbox.finishMemo(original, segmentCount: 2)
    await outbox.settled()

    #expect(await base.created.map(\.memoID) == [original, tail])
    #expect(await base.completed.contains(.init(memoID: tail, segmentCount: 1)))
    #expect(await outbox.queue().isEmpty)
    await outbox.shutdown()
  }

  @Test func aSegmentFileThatIsGoneStallsAndMakesNoMemo() async throws {
    let base = TestUploader()
    let uploader = LateTailUploader(base: base, late: [SegmentKey(memoID: original, index: 0)])
    let outbox = try await outbox(uploader)

    try await outbox.enqueueItem(voiceItem(original))
    await outbox.enqueue(segment(original, 0))  // /tmp/iris-test/0.m4a: not there
    await outbox.finishMemo(original, segmentCount: 1)
    await outbox.settled()

    #expect(await base.created.map(\.memoID) == [original])
    let row = try #require(await outbox.queue().first)
    guard case .failed(let retryAt, let reason) = row.status else {
      Issue.record("expected a stalled row, got \(row.status)")
      return
    }
    #expect(retryAt == nil && reason == "the recording file is gone")
    await outbox.shutdown()
  }

  @Test func aCopyCutOffHalfWayLeavesNothingUnderTheRealName() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source.m4a")
    let target = directory.appending(path: "target.m4a")
    try Data("audio-1".utf8).write(to: source)
    var cutOff = LateTail.FileOperations()
    cutOff.link = { _, _ in throw CocoaError(.fileWriteVolumeReadOnly) }
    cutOff.copy = { from, to in
      try Data("aud".utf8).write(to: to)  // half of it is on disk when the copy fails
      throw CocoaError(.fileWriteOutOfSpace)
    }

    #expect(throws: CocoaError.self) { try LateTail.link(source, as: target, using: cutOff) }
    #expect(!FileManager.default.fileExists(atPath: target.path), "a retry must not find a partial file to reuse")
    #expect(!FileManager.default.fileExists(atPath: target.appendingPathExtension("partial").path))

    var copyOnly = LateTail.FileOperations()
    copyOnly.link = { _, _ in throw CocoaError(.fileWriteVolumeReadOnly) }
    try LateTail.link(source, as: target, using: copyOnly)
    #expect(try Data(contentsOf: target) == Data("audio-1".utf8))
  }

  @Test func anExistingTargetIsReusedOnlyWhenItIsAsLargeAsTheSource() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "source.m4a")
    let target = directory.appending(path: "target.m4a")
    try Data("audio-1".utf8).write(to: source)

    try Data("aud".utf8).write(to: target)  // left by a run that died while writing
    try LateTail.link(source, as: target)
    #expect(try Data(contentsOf: target) == Data("audio-1".utf8), "the short file was replaced")

    try LateTail.link(source, as: target)  // complete already: left alone
    #expect(try Data(contentsOf: target) == Data("audio-1".utf8))
  }

  @Test func theDerivedIDIsStableDistinctAndAValidUUID() {
    let one = LateTail.memoID(of: original, index: 1)
    #expect(one == LateTail.memoID(of: original, index: 1))
    #expect(one != LateTail.memoID(of: original, index: 2))
    #expect(one != LateTail.memoID(of: memo(2), index: 1))
    #expect(UUID(uuidString: one.uuidString) == one)
  }
}
