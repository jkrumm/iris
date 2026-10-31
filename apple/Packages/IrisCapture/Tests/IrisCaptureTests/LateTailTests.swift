import Foundation
import Testing

@testable import IrisCapture

/// A late tail (`LateTail.swift`): the end of a take that the server's closed memo cannot take becomes its own transcribe memo.
struct LateTailTests {
  private let take = memo(1)
  private let directory: URL
  private var tailID: MemoID { LateTail.memoID(of: take, index: 1) }
  private var tailKey: SegmentKey { SegmentKey(memoID: tailID, index: 0) }

  init() throws { directory = try temporaryDirectory() }

  private func file(_ memoID: MemoID, _ index: Int) -> URL {
    directory.appending(path: "\(memoID.uuidString)-\(index).m4a")
  }

  private func closed(_ index: Int, of memoID: MemoID? = nil) throws -> ClosedSegment {
    let id = memoID ?? take
    let url = file(id, index)
    try Data("audio-\(index)".utf8).write(to: url)
    return ClosedSegment(memoID: id, index: index, fileURL: url, byteCount: 7, duration: 3)
  }

  /// A take of `count` finished segments, all on disk and queued, its `create` done: what the queue file holds after a kill.
  private func record(count: Int = 2, segments: [Int]? = nil, completed: [MemoID] = []) throws -> OutboxRecord {
    var item = voiceItem(take)
    item.create = .uploaded
    item.title = "Standup"
    let entries = try (segments ?? Array(0..<count)).enumerated().map { position, index in
      OutboxEntry(segment: try closed(index), sequence: position, state: .pending, attempts: 0)
    }
    return OutboxRecord(
      entries: entries, memos: [OutboxMemo(memoID: take, segmentCount: count, completion: .pending, attempts: 0)],
      items: [item], nextSequence: entries.count, completedMemos: completed)
  }

  private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  @Test("the closed-memo answer makes exactly one transcribe memo of the segment, named after its take")
  func closedMemoSegmentBecomesATranscribeMemo() async throws {
    let uploader = TestUploader()
    await uploader.closeMemo(for: SegmentKey(memoID: take, index: 1))
    let harness = try await OutboxHarness(record: try record(), uploader: uploader)
    await harness.outbox.settled()

    let tails = await uploader.created.filter { $0.tailOf != nil }
    #expect(tails.count == 1)
    #expect(tails.first?.memoID == tailID)
    #expect(tails.first?.mode == "transcribe")
    #expect(tails.first?.kind == .voice)
    #expect(tails.first?.threadID == nil)
    #expect(tails.first?.tailOf == take)
    #expect(tails.first?.title.contains("Standup") == true)
    #expect(await uploader.uploaded.contains(tailKey))
    let completed = await uploader.completed
    #expect(completed.contains { $0.memoID == tailID && $0.segmentCount == 1 })
    #expect(completed.contains { $0.memoID == take })
  }

  @Test("delivery removes both names of the file, the take's with the take and the tail's with the tail")
  func deliveryDeletesTheFiles() async throws {
    let uploader = TestUploader()
    await uploader.closeMemo(for: SegmentKey(memoID: take, index: 1))
    let harness = try await OutboxHarness(record: try record(), uploader: uploader)
    await harness.outbox.settled()
    await harness.outbox.flush()
    #expect(!exists(file(take, 1)) && !exists(file(take, 0)))
    #expect(!exists(file(tailID, 0)))
  }

  @Test("the tail's file is not deleted before its memo is delivered, even when the take is done")
  func fileSurvivesUntilDelivered() async throws {
    let uploader = TestUploader()
    await uploader.closeMemo(for: SegmentKey(memoID: take, index: 1))
    await uploader.holdCreates()
    let harness = try await OutboxHarness(record: try record(), uploader: uploader)
    await uploader.waitUntilCreateAttempts(1)
    // The take is delivered or being delivered; the tail's create is on the wire.
    await harness.outbox.flush()
    #expect(exists(file(tailID, 0)))
    #expect(try Data(contentsOf: file(tailID, 0)) == Data("audio-1".utf8))
    await uploader.releaseAll()
    await harness.outbox.settled()
    #expect(!exists(file(tailID, 0)))
  }

  @Test("a replay never makes a second memo: a tail that was delivered is not queued again")
  func replayAfterDeliveryIsANoOp() async throws {
    let uploader = TestUploader()
    await uploader.closeMemo(for: SegmentKey(memoID: take, index: 1))
    let harness = try await OutboxHarness(record: try record(completed: [tailID]), uploader: uploader)
    await harness.outbox.settled()
    #expect(await uploader.created.filter { $0.tailOf != nil }.isEmpty)
    #expect(await harness.outbox.items().isEmpty)
    #expect(!exists(file(tailID, 0)))
    #expect(await uploader.completed.contains { $0.memoID == take })
  }

  @Test("a crash between the decision and the save: the relaunch decides again and lands on the same single memo")
  func crashBetweenDecisionAndSave() async throws {
    let saved = try record()
    let first = TestUploader()
    await first.closeMemo(for: SegmentKey(memoID: take, index: 1))
    await first.holdCreates()
    let before = try await OutboxHarness(record: saved, uploader: first)
    await first.waitUntilCreateAttempts(1)
    await before.outbox.shutdown()
    #expect(exists(file(tailID, 0)))  // the second name was made; the queue file we relaunch from does not know it

    let second = TestUploader()
    await second.closeMemo(for: SegmentKey(memoID: take, index: 1))
    let after = try await OutboxHarness(record: saved, uploader: second)
    await after.outbox.settled()
    #expect(await second.created.filter { $0.tailOf != nil }.map(\.memoID) == [tailID])
    #expect(await second.uploaded.contains(tailKey))
    #expect(!exists(file(tailID, 0)))
  }

  @Test("the startup sweep sets aside a second name nobody saved, and the take's own files stay")
  func sweepSetsTheUnsavedNameAside() async throws {
    let harness = try await OutboxHarness(record: try record(), uploader: TestUploader())
    let orphan = try closed(0, of: tailID).fileURL
    let report = await harness.outbox.sweepOrphans(using: DirectorySegmentFiles(directory: directory))
    #expect(report.quarantined.count == 1)
    #expect(!exists(orphan))
    #expect(exists(file(take, 0)) && exists(file(take, 1)))
  }

  @Test("discarding the tail's row removes it and its file; the take is unaffected and the tail is not resurrected")
  func discardOfTheTailItem() async throws {
    let uploader = TestUploader()
    await uploader.closeMemo(for: SegmentKey(memoID: take, index: 1))
    await uploader.holdCreates()
    let harness = try await OutboxHarness(record: try record(), uploader: uploader)
    await uploader.waitUntilCreateAttempts(1)
    #expect(await harness.outbox.discard(tailID))
    await uploader.releaseAll()
    await harness.outbox.settled()
    #expect(!exists(file(tailID, 0)))
    #expect(await harness.outbox.items().allSatisfy { $0.memoID != tailID })
    #expect(await uploader.completed.contains { $0.memoID == take })
    #expect(!(await uploader.completed.contains { $0.memoID == tailID }))
  }

  @Test("a segment past the count `complete` carried is diverted before the take's entries go, not deleted with them")
  func segmentPastTheCompletedCount() async throws {
    let uploader = TestUploader()
    // Still unsent when `complete` for count 1 lands.
    await uploader.failNext(1, for: SegmentKey(memoID: take, index: 1))
    let saved = try record(count: 1, segments: [0, 1])
    let harness = try await OutboxHarness(record: saved, uploader: uploader)
    await harness.outbox.settled()
    #expect(await uploader.completed.contains { $0.memoID == take && $0.segmentCount == 1 })
    #expect(await uploader.created.contains { $0.memoID == tailID })
    #expect(await uploader.uploaded.contains(tailKey))
  }

  @Test("a segment that closes after its take completed is queued as a tail; one of a discarded take is not")
  func enqueueAfterCompletion() async throws {
    let uploader = TestUploader()
    let harness = try await OutboxHarness(record: try record(count: 1), uploader: uploader)
    await harness.outbox.settled()
    #expect(await uploader.completed.contains { $0.memoID == take })

    await harness.outbox.enqueue(try closed(1))
    await harness.outbox.settled()
    #expect(await uploader.created.filter { $0.tailOf == take }.map(\.memoID) == [tailID])
    #expect(await uploader.uploaded.contains(tailKey))
    await harness.outbox.enqueue(try closed(1))  // the same segment again: still one memo
    await harness.outbox.settled()
    #expect(await uploader.created.filter { $0.tailOf != nil }.count == 1)

    let other = memo(2)
    var item = voiceItem(other)
    item.create = .uploaded
    #expect(try await harness.outbox.enqueueItem(item))
    await harness.outbox.discard(other)
    await harness.outbox.enqueue(try closed(0, of: other))
    await harness.outbox.settled()
    #expect(await uploader.created.filter { $0.tailOf == other }.isEmpty)
  }

  @Test("a file that cannot be given a second name stays where it is and the entry backs off")
  func noSecondNameKeepsTheFile() async throws {
    let uploader = TestUploader()
    await uploader.closeMemo(for: SegmentKey(memoID: take, index: 1))
    let saved = try record()
    try FileManager.default.removeItem(at: file(take, 1))
    let harness = try await OutboxHarness(record: saved, uploader: uploader)
    await harness.outbox.settled()
    #expect(await uploader.created.filter { $0.tailOf != nil }.isEmpty)
    #expect(await harness.outbox.entries().first { $0.key.index == 1 }?.state != .uploaded)
  }

  @Test("the segment of a tail is never diverted again")
  func tailOfATailStaysPut() async throws {
    let uploader = TestUploader()
    await uploader.closeMemo(for: SegmentKey(memoID: take, index: 1))
    await uploader.closeMemo(for: tailKey)
    let harness = try await OutboxHarness(record: try record(), uploader: uploader)
    await harness.outbox.settled()
    #expect(await uploader.created.filter { $0.tailOf != nil }.count == 1)
    #expect(await harness.outbox.entries().first { $0.key == tailKey }?.state != .uploaded)
    #expect(exists(file(tailID, 0)))
  }

  @Test("the derived id is a stable UUIDv5 that differs per take and index")
  func derivedID() {
    #expect(LateTail.memoID(of: take, index: 1) == LateTail.memoID(of: take, index: 1))
    #expect(LateTail.memoID(of: take, index: 1) != LateTail.memoID(of: take, index: 2))
    #expect(LateTail.memoID(of: take, index: 1) != LateTail.memoID(of: memo(2), index: 1))
    let bytes = withUnsafeBytes(of: LateTail.memoID(of: take, index: 1).uuid) { Array($0) }
    #expect(bytes[6] >> 4 == 5 && bytes[8] >> 6 == 0b10)
  }

  @Test("the tail marker survives the queue file, and a record without it reads nil")
  func tailMarkerIsPersisted() throws {
    var item = voiceItem(tailID)
    item.tailOf = take
    let decoded = try JSONDecoder().decode(OutboxItem.self, from: JSONEncoder().encode(item))
    #expect(decoded.tailOf == take)
    var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
    json["tailOf"] = nil
    let plain = try JSONDecoder().decode(OutboxItem.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(plain.tailOf == nil)
  }
}
