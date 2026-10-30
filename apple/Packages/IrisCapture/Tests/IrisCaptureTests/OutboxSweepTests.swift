import Foundation
import Testing

@testable import IrisCapture

/// The startup sweep of the capture directory: a file no saved record names is adopted by its take or moved aside, never
/// deleted.
struct OutboxSweepTests {
  private func file(_ directory: URL, _ id: MemoID, _ index: Int, _ contents: String = "audio") throws -> URL {
    let url = directory.appending(path: "\(id.uuidString)-\(index).m4a")
    try Data(contents.utf8).write(to: url)
    return url
  }

  /// Complete files hold "audio"; anything else is a truncated one.
  private let inspect: SegmentInspector = { url in
    guard let data = try? Data(contentsOf: url), String(data: data, encoding: .utf8) == "audio" else { return nil }
    return (data.count, 10)
  }

  private func files(_ directory: URL, quarantine: URL? = nil) -> DirectorySegmentFiles {
    DirectorySegmentFiles(directory: directory, quarantineDirectory: quarantine, inspect: inspect)
  }

  private func contents(_ directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
  }

  /// The queue as the last save left it: a take with segments 0 and 1, then a crash before segment 2 was saved.
  private func crashedTake(_ id: MemoID, in directory: URL) throws -> OutboxRecord {
    var item = voiceItem(id)
    item.create = .uploaded
    item.createMayHaveLanded = true
    let entries = try (0..<2).map { index in
      OutboxEntry(
        segment: ClosedSegment(
          memoID: id, index: index, fileURL: try file(directory, id, index), byteCount: 5, duration: 10),
        sequence: index, state: .uploaded, attempts: 0)
    }
    return OutboxRecord(entries: entries, items: [item], nextSequence: 2)
  }

  @Test func theNextSegmentsOfACrashedTakeAreAdoptedAndTheTakeGrows() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = memo(1)
    let record = try crashedTake(id, in: directory)
    _ = try file(directory, id, 2)
    _ = try file(directory, id, 3)
    let harness = try await OutboxHarness(record: record)

    let report = await harness.outbox.sweepOrphans(using: files(directory))

    #expect(report.adopted.map(\.lastPathComponent) == ["\(id.uuidString)-2.m4a", "\(id.uuidString)-3.m4a"])
    #expect(report.quarantined.isEmpty)
    #expect(await harness.outbox.memos().first?.segmentCount == 4, "the recovered take grows by what the sweep found")
    #expect(await harness.outbox.entries().count == 4)
    let saved = await harness.store.load()
    #expect(saved.entries.count == 4 && saved.memos.first?.segmentCount == 4, "saved before anything goes up")

    await harness.outbox.settled()
    #expect(await harness.uploader.uploaded.map(\.index).sorted() == [2, 3], "only the adopted ones need sending")
    #expect(await harness.uploader.completed == [.init(memoID: id, segmentCount: 4)])
    await harness.outbox.shutdown()
  }

  @Test func aTruncatedFileAFileOfNoTakeAndAGapAreQuarantinedNotDeleted() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = memo(1)
    let record = try crashedTake(id, in: directory)
    let truncated = try file(directory, id, 2, "half")
    let afterTheGap = try file(directory, id, 5)
    let foreign = try file(directory, memo(9), 0)
    let stray = directory.appending(path: "notes.m4a")
    try Data("audio".utf8).write(to: stray)
    let harness = try await OutboxHarness(record: record)
    let quarantine = directory.appending(path: "quarantine")

    let report = await harness.outbox.sweepOrphans(using: files(directory, quarantine: quarantine))

    #expect(report.adopted.isEmpty)
    #expect(report.quarantined.count == 4)
    for original in [truncated, afterTheGap, foreign, stray] {
      #expect(!FileManager.default.fileExists(atPath: original.path), "moved out of the capture directory")
      #expect(
        FileManager.default.fileExists(atPath: quarantine.appending(path: original.lastPathComponent).path),
        "and kept: \(original.lastPathComponent)")
    }
    #expect(await harness.outbox.entries().count == 2, "the take is as the saved queue had it")
    await harness.outbox.shutdown()
  }

  @Test func aFilledGapInAFinishedTakeIsAdopted() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = memo(1)
    var item = voiceItem(id)
    item.create = .uploaded
    item.createMayHaveLanded = true
    let present = try file(directory, id, 0)
    let missing = try file(directory, id, 1)
    let record = OutboxRecord(
      entries: [
        OutboxEntry(
          segment: ClosedSegment(memoID: id, index: 0, fileURL: present, byteCount: 5, duration: 10), sequence: 0,
          state: .uploaded, attempts: 0)
      ], memos: [OutboxMemo(memoID: id, segmentCount: 2, completion: .pending, attempts: 0)], items: [item],
      nextSequence: 1)
    let harness = try await OutboxHarness(record: record)

    let report = await harness.outbox.sweepOrphans(using: files(directory))

    #expect(report.adopted == [missing])
    // A finished take never grows: a file past its count is not part of it.
    let beyond = try file(directory, id, 2)
    let second = await harness.outbox.sweepOrphans(using: files(directory))
    #expect(second.adopted.isEmpty)
    #expect(second.quarantined.count == 1 && !FileManager.default.fileExists(atPath: beyond.path))
    await harness.outbox.shutdown()
  }

  @Test func filesTheQueueOwnsAreLeftAlone() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = memo(1)
    let record = try crashedTake(id, in: directory)
    let harness = try await OutboxHarness(record: record)

    let report = await harness.outbox.sweepOrphans(using: files(directory))

    #expect(report.isEmpty)
    #expect(contents(directory).count == 2)
    await harness.outbox.shutdown()
  }

  @Test func filesANamedByAQuarantinedQueueStayWhereTheyAre() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let named = try file(directory, memo(1), 0)
    let other = try file(directory, memo(2), 0)
    // The queue file that was set aside names the first segment.
    let queueFile = directory.appending(path: "outbox.quarantined-1.json")
    try Data("{ \"entries\": [{\"fileURL\": \"\(named.path)\"}".utf8).write(to: queueFile)
    let store = HeldQueueStore(files: [queueFile])
    let outbox = try await Outbox(store: store, uploader: TestUploader(), clock: ManualClock())

    let report = await outbox.sweepOrphans(using: files(directory))

    #expect(report.kept == [named])
    #expect(report.quarantined.map(\.lastPathComponent) == [other.lastPathComponent])
    #expect(FileManager.default.fileExists(atPath: named.path))
    await outbox.shutdown()
  }

  @Test func aSetAsideQueueThatCannotBeReadKeepsEveryCandidateInPlace() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try file(directory, memo(1), 0)
    let second = try file(directory, memo(2), 0)
    // A set-aside queue file that is not there to read: it may name either file.
    let missing = directory.appending(path: "outbox.quarantined-gone.json")
    let outbox = try await Outbox(
      store: HeldQueueStore(files: [missing]), uploader: TestUploader(), clock: ManualClock())

    let report = await outbox.sweepOrphans(using: files(directory))

    #expect(Set(report.kept) == [first, second])
    #expect(report.quarantined.isEmpty && report.adopted.isEmpty)
    #expect(FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path))
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "quarantine").path))
    await outbox.shutdown()
  }

  @Test func aNameTakenInTheQuarantineFolderKeepsBothFiles() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let quarantine = directory.appending(path: "quarantine")
    try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
    let id = memo(3)
    try Data("older".utf8).write(to: quarantine.appending(path: "\(id.uuidString)-0.m4a"))
    _ = try file(directory, id, 0)
    let harness = try await OutboxHarness()

    let report = await harness.outbox.sweepOrphans(using: files(directory, quarantine: quarantine))

    #expect(report.quarantined.count == 1)
    #expect(contents(quarantine).count == 2, "nothing is overwritten")
    await harness.outbox.shutdown()
  }

  @Test func theFileNameIsTheRecorders() {
    let id = memo(7)
    #expect(Outbox.parse("\(id.uuidString)-12.m4a")?.0 == id)
    #expect(Outbox.parse("\(id.uuidString)-12.m4a")?.1 == 12)
    #expect(Outbox.parse("notes.m4a") == nil)
    #expect(Outbox.parse("\(id.uuidString).m4a") == nil)
    #expect(Outbox.parse("\(id.uuidString)-x.m4a") == nil)
  }

  @Test func theFilesASweepSetAsideAreListedWithTheirSize() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stray = directory.appending(path: "notes.m4a")
    try Data("not audio".utf8).write(to: stray)
    let harness = try await OutboxHarness()
    let store = files(directory)
    #expect(await store.setAsideFiles().isEmpty)

    await harness.outbox.sweepOrphans(using: store)

    let listed = await store.setAsideFiles()
    #expect(listed.map(\.url.lastPathComponent) == ["notes.m4a"])
    #expect(listed.first?.byteCount == 9 && listed.first?.modifiedAt != nil)
    await harness.outbox.shutdown()
  }
}

/// A store with an empty queue and some queue files set aside.
private struct HeldQueueStore: OutboxStore {
  let files: [URL]

  func load() async throws -> OutboxRecord { OutboxRecord() }
  func save(_ record: OutboxRecord) async throws {}
  func quarantined() async -> [URL] { files }
}
