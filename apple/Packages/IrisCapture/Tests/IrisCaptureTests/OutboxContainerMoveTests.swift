import Foundation
import Testing

@testable import IrisCapture

/// The app's data container gets a new path when a build is installed over it, and a saved queue that named its segment
/// files by absolute path then pointed at nothing: every upload failed with "the recording file is gone" and stalled, with
/// the audio untouched in the new container. The queue names files by name; the store puts them in the current directory.
struct OutboxContainerMoveTests {
  private let oldDirectory = URL(
    fileURLWithPath: "/var/mobile/Containers/Data/Application/OLD-CONTAINER/Library/Application Support/Iris/capture")

  /// Like production: a segment that is not at the path it names is permanent, not retried.
  private actor FileReadingUploader: SegmentUploader {
    private(set) var uploaded: [String] = []
    private(set) var completed: [Int] = []

    func create(_ item: OutboxItem) async throws {}

    func upload(_ segment: ClosedSegment) async throws {
      guard FileManager.default.fileExists(atPath: segment.fileURL.path) else {
        throw PermanentTransferError("the recording file is gone")
      }
      uploaded.append(segment.fileURL.lastPathComponent)
    }

    func complete(memoID: MemoID, segmentCount: Int) async throws { completed.append(segmentCount) }
    func delete(memoID: MemoID) async throws {}
  }

  private struct Rig {
    let root: URL
    let capture: URL
    let queueFile: URL
    let id = memo(9)

    var store: JSONFileOutboxStore { JSONFileOutboxStore(fileURL: queueFile, segmentDirectory: capture) }
  }

  private func rig() throws -> Rig {
    let root = try temporaryDirectory()
    let capture = root.appending(path: "capture")
    try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
    return Rig(root: root, capture: capture, queueFile: root.appending(path: "outbox.json"))
  }

  private func fileName(_ id: MemoID, _ index: Int) -> String { "\(id.uuidString)-\(index).m4a" }

  /// The queue as the phone had it: a take created on the server, three segments stalled at an old container path, the
  /// files themselves in the current capture directory.
  private func saveStalledQueue(_ rig: Rig, state: OutboxState = .stalled, files: Bool = true) async throws {
    var item = voiceItem(rig.id)
    item.create = .uploaded
    item.createMayHaveLanded = true
    item.lastError = "the recording file is gone"
    var machine = OutboxStateMachine()
    machine.enqueueItem(item)
    for index in 0..<3 {
      let stale = ClosedSegment(
        memoID: rig.id, index: index, fileURL: oldDirectory.appending(path: fileName(rig.id, index)), byteCount: 5,
        duration: 1)
      machine.enqueue(stale)
      if files { try Data("audio".utf8).write(to: rig.capture.appending(path: fileName(rig.id, index))) }
    }
    machine.finishMemo(rig.id, segmentCount: 3)
    var record = machine.record
    record.entries = record.entries.map {
      var entry = $0; entry.state = state; entry.attempts = 1; return entry
    }
    // Written without a directory to resolve against: the absolute paths stay in the file, as the old build wrote them.
    try await JSONFileOutboxStore(fileURL: rig.queueFile).save(record)
  }

  @Test func stalledSegmentsAtAnOldContainerPathAreSentFromTheCurrentDirectory() async throws {
    let rig = try rig()
    defer { try? FileManager.default.removeItem(at: rig.root) }
    try await saveStalledQueue(rig)

    let uploader = FileReadingUploader()
    let outbox = try await Outbox(
      store: rig.store, uploader: uploader, clock: ManualClock(), policy: OutboxPolicy(jitter: { 0 }),
      deletesFilesWhenDone: false)
    await outbox.settled()

    #expect(await uploader.uploaded.sorted() == (0..<3).map { fileName(rig.id, $0) })
    #expect(await uploader.completed == [3])
    #expect(await outbox.entries().isEmpty, "the memo is done: nothing is left in the queue")
    #expect(await outbox.items().isEmpty)
    await outbox.shutdown()
  }

  @Test func theQueueFileNamesSegmentsWithoutTheContainerPath() async throws {
    let rig = try rig()
    defer { try? FileManager.default.removeItem(at: rig.root) }
    try await saveStalledQueue(rig)

    let uploader = FileReadingUploader()
    let outbox = try await Outbox(
      store: rig.store, uploader: uploader, clock: ManualClock(), policy: OutboxPolicy(jitter: { 0 }),
      deletesFilesWhenDone: false)
    await outbox.flush()

    let saved = try String(contentsOf: rig.queueFile, encoding: .utf8)
    #expect(!saved.contains("Containers"), "no container path is saved")
    #expect(saved.contains(fileName(rig.id, 0)))
    await outbox.shutdown()
  }

  @Test func aStalledSegmentWhoseFileIsReallyGoneStaysStalled() async throws {
    let rig = try rig()
    defer { try? FileManager.default.removeItem(at: rig.root) }
    try await saveStalledQueue(rig, files: false)

    let uploader = FileReadingUploader()
    let outbox = try await Outbox(
      store: rig.store, uploader: uploader, clock: ManualClock(), policy: OutboxPolicy(jitter: { 0 }),
      deletesFilesWhenDone: false)
    await outbox.settled()

    #expect(await uploader.uploaded.isEmpty)
    #expect(await outbox.entries().map(\.state) == [.stalled, .stalled, .stalled], "no retry loop on a lost file")
    await outbox.shutdown()
  }

  @Test func aSegmentStalledForAnotherReasonIsNotRetriedByTheHeal() async throws {
    let rig = try rig()
    defer { try? FileManager.default.removeItem(at: rig.root) }
    try await saveStalledQueue(rig)
    // Opened and saved once: the names are now relative, so this queue is no longer one the heal touches.
    let first = try await Outbox(
      store: rig.store, uploader: TestUploader(), clock: ManualClock(), policy: OutboxPolicy(jitter: { 0 }),
      deletesFilesWhenDone: false)
    await first.flush()
    var record = try await rig.store.load()
    record.entries = record.entries.map {
      var entry = $0; entry.state = .stalled; return entry
    }
    try await rig.store.save(record)
    await first.shutdown()

    let uploader = FileReadingUploader()
    let outbox = try await Outbox(
      store: rig.store, uploader: uploader, clock: ManualClock(), policy: OutboxPolicy(jitter: { 0 }),
      deletesFilesWhenDone: false)
    await outbox.settled()

    #expect(await uploader.uploaded.isEmpty)
    #expect(await outbox.entries().map(\.state) == [.stalled, .stalled, .stalled])
    await outbox.shutdown()
  }
}
