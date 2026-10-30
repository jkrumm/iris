import Foundation
import Testing

@testable import IrisCapture

/// Wraps `TestUploader`: the listed segments are refused as a late tail (the server closed their memo without them), and
/// creates of `holding` memos wait until `release()`.
private actor LateTailUploader: SegmentUploader {
  let base: TestUploader
  private let late: Set<SegmentKey>
  private var holding: Set<MemoID> = []
  private var held: [CheckedContinuation<Void, Never>] = []

  init(base: TestUploader, late: Set<SegmentKey>) {
    self.base = base
    self.late = late
  }

  func holdCreates(of ids: Set<MemoID>) { holding = ids }

  func release() {
    holding = []
    let waiting = held
    held = []
    for continuation in waiting { continuation.resume() }
  }

  func create(_ item: OutboxItem) async throws {
    if holding.contains(item.memoID) { await withCheckedContinuation { held.append($0) } }
    try await base.create(item)
  }

  func upload(_ segment: ClosedSegment) async throws {
    if late.contains(SegmentKey(memoID: segment.memoID, index: segment.index)) {
      throw LateSegmentError(label: "Late recording", answer: "no longer receiving")
    }
    try await base.upload(segment)
  }

  func complete(memoID: MemoID, segmentCount: Int) async throws {
    try await base.complete(memoID: memoID, segmentCount: segmentCount)
  }

  func delete(memoID: MemoID) async throws { try await base.delete(memoID: memoID) }
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
    #expect(await base.completed.contains(.init(memoID: original, segmentCount: 2)))

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
    #expect(await base.completed.contains(.init(memoID: original, segmentCount: 2)))
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

  @Test func theDerivedIDIsStableDistinctAndAValidUUID() {
    let one = LateTail.memoID(of: original, index: 1)
    #expect(one == LateTail.memoID(of: original, index: 1))
    #expect(one != LateTail.memoID(of: original, index: 2))
    #expect(one != LateTail.memoID(of: memo(2), index: 1))
    #expect(UUID(uuidString: one.uuidString) == one)
  }
}
