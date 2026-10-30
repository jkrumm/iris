import Foundation
import IrisCapture
import IrisCore
import Synchronization
import Testing

@testable import Iris

private func waitFor(seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
  for _ in 0..<Int(seconds * 100) {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return await condition()
}

private func makeStack(store: any OutboxStore, captureDirectory: URL? = nil) -> (CaptureStack, OutboxService) {
  let capture = FakeCapture(
    directory: FileManager.default.temporaryDirectory.appending(path: "iris-reset-\(UUID().uuidString)"))
  let created = CreatedMemoLog()
  let stack = CaptureStack(
    .init(
      session: capture.session, routes: capture.routes, recorder: capture.recorder, clock: ManualClock(), store: store,
      uploader: APIOutboxUploader(client: FakeAPIClient(), created: created),
      segmentFiles: captureDirectory.map { DirectorySegmentFiles(directory: $0) }))
  return (stack, OutboxService(stack: stack, created: created))
}

/// "Reset outbox": an outbox file that cannot be decoded is renamed aside and kept, and a fresh outbox opens.
@MainActor
@Suite("Outbox reset")
struct OutboxResetTests {
  @Test("an unreadable outbox is reported as such, not as a queue that is merely closed")
  func unreadable() async {
    let (stack, service) = makeStack(store: UnreadableOutboxStore())
    #expect(await stack.availability() == .unreadable)
    #expect(await service.isUnreadable())
    #expect(await !service.isAvailable())
    await #expect(throws: CaptureStackError.queueUnavailable) { try await stack.outbox() }
  }

  @Test("an outbox that cannot be opened has unknown pending deletes, not none; an empty one has none")
  func pendingDeletionsAreUnknownWhenUnreadable() async {
    let (_, unreadable) = makeStack(store: UnreadableOutboxStore())
    #expect(await unreadable.pendingDeletionIDs() == nil)

    let (_, healthy) = makeStack(store: InMemoryOutboxStore())
    #expect(await healthy.pendingDeletionIDs() == [])
  }

  @Test("a queue that fails to load for another reason is unavailable, and a reset refuses to touch it")
  func notResettable() async {
    let (stack, service) = makeStack(store: FailingStore())
    #expect(await stack.availability() == .unavailable)
    #expect(await service.resetOutbox() == .notReset)
    await #expect(throws: CaptureStackError.queueUnavailable) { try await stack.resetOutbox() }
  }

  @Test("the reset sets the file aside, opens a fresh outbox and accepts new work")
  func reset() async throws {
    let store = UnreadableOutboxStore()
    let (stack, service) = makeStack(store: store)
    #expect(await service.quarantinedFiles().isEmpty)

    #expect(await service.resetOutbox() == .reset)

    #expect(await stack.availability() == .available)
    #expect(await service.queuedItems().isEmpty)
    #expect(await service.quarantinedFiles().count == 1, "the old file is kept, not deleted")
    let outcome = await service.submitText(
      TextSubmission(id: MemoID(), mode: .auto, text: "hello", threadId: nil, startedAt: Date()))
    #expect(outcome != .refused, "the fresh outbox takes new items")
    #expect(await service.resetOutbox() == .notReset, "a second reset has nothing to set aside")
  }

  @Test("Settings offers the reset only while the file is unreadable, and shows the set-aside file afterwards")
  func settings() async throws {
    let (_, service) = makeStack(store: UnreadableOutboxStore())
    let model = SettingsModel(client: FakeAPIClient(), queue: service)
    await model.load()
    #expect(model.queueUnreadable && model.queueUnavailable)
    #expect(model.quarantinedFiles.isEmpty)

    await model.resetOutbox()

    #expect(!model.queueUnreadable && !model.queueUnavailable && !model.resetFailed)
    #expect(model.quarantinedFiles.count == 1, "Diagnostics can share it")

    await model.resetOutbox()
    #expect(!model.resetFailed, "nothing to reset is not a failure")
  }

  @Test("a reset that cannot move the file says so and changes nothing")
  func resetFailure() async {
    let (_, service) = makeStack(store: UnmovableStore())
    let model = SettingsModel(client: FakeAPIClient(), queue: service)
    await model.load()
    #expect(model.queueUnreadable)

    await model.resetOutbox()

    #expect(model.resetFailed)
    #expect(model.queueUnreadable)
  }

  @Test("a reset whose new outbox will not open says the file is set aside, not that nothing changed")
  func resetThenReopenFails() async {
    let (_, service) = makeStack(store: MovesThenFailsStore())
    let model = SettingsModel(client: FakeAPIClient(), queue: service)
    await model.load()
    #expect(model.queueUnreadable)

    await model.resetOutbox()

    #expect(model.resetLeftUnopened, "the truth: the old file is kept, no new outbox yet")
    #expect(!model.resetFailed, "and it is not \"nothing was changed\"")
    #expect(!model.queueUnreadable && model.queueUnavailable)
    #expect(model.quarantinedFiles.count == 1)
  }

  @Test("a discard that cannot reach the outbox says so instead of looking done")
  func discardWithoutAnOutbox() async {
    let (_, service) = makeStack(store: UnreadableOutboxStore())
    #expect(await !service.discard(MemoID()))
    #expect(await !service.discardQueued(id: MemoID().wireID))

    let model = SettingsModel(client: FakeAPIClient(), queue: service)
    let row = QueuedItem(id: MemoID().wireID, kind: .voiceMemo, title: "x", queuedAt: Date(), state: .waiting)
    await model.discard(row)
    #expect(model.discardFailed)
  }

  @Test("a discard that cannot reach the outbox does not hide the memo")
  func discardWithoutAnOutboxKeepsTheMemoVisible() async {
    let (_, service) = makeStack(store: UnreadableOutboxStore())
    let forgotten = Mutex<[String]>([])
    await service.created.setForgottenHandler { id in forgotten.withLock { $0.append(id) } }
    let id = MemoID()

    #expect(await !service.discard(id))
    #expect(await !service.discardQueued(id: id.wireID))

    #expect(forgotten.withLock { $0 }.isEmpty, "nothing queued a DELETE, so History keeps showing the memo")
  }

  @Test("a discard that reaches the outbox hides the memo")
  func discardHidesTheMemo() async {
    let (_, service) = makeStack(store: InMemoryOutboxStore())
    let forgotten = Mutex<[String]>([])
    await service.created.setForgottenHandler { id in forgotten.withLock { $0.append(id) } }
    let id = MemoID()

    #expect(await service.discard(id))

    #expect(forgotten.withLock { $0 } == [id.wireID])
  }

  @Test("a second Reset tap while the first runs joins it instead of reporting a failure")
  func secondResetJoinsTheFirst() async throws {
    let store = SlowQuarantineStore()
    let (stack, service) = makeStack(store: store)
    #expect(await stack.availability() == .unreadable)

    let first = Task { await service.resetOutbox() }
    await store.waitUntilMoving()
    let second = Task { await service.resetOutbox() }
    try await Task.sleep(for: .milliseconds(50))  // the second tap is waiting on the first
    await store.finishMoving()

    #expect(await first.value == .reset)
    #expect(await second.value == .reset, "joined, not `notReset`")
    #expect(await store.moves == 1, "the file moved once")
    #expect(await stack.availability() == .available)
  }

  @Test("opening the outbox sweeps the capture directory: strays are moved aside, never deleted")
  func sweepAtOpen() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "iris-sweep-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stray = directory.appending(path: "\(UUID().uuidString)-0.m4a")
    try Data("half a take".utf8).write(to: stray)
    let (stack, _) = makeStack(store: InMemoryOutboxStore(), captureDirectory: directory)

    _ = try await stack.outbox()

    #expect(!FileManager.default.fileExists(atPath: stray.path))
    let moved = directory.appending(path: "quarantine").appending(path: stray.lastPathComponent)
    #expect(try Data(contentsOf: moved) == Data("half a take".utf8))
  }

  @Test("what the sweep and a reset set aside is counted with its size, listed for sharing and never deleted")
  func setAsideSummary() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "iris-setaside-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stray = directory.appending(path: "\(UUID().uuidString)-0.m4a")
    try Data("half a take".utf8).write(to: stray)
    let (stack, service) = makeStack(store: InMemoryOutboxStore(), captureDirectory: directory)
    _ = try await stack.outbox()  // the sweep moves the stray into quarantine/

    let model = SettingsModel(client: FakeAPIClient(), queue: service)
    await model.load()

    #expect(model.setAside.recordings.count == 1 && model.setAside.byteCount == 11)
    #expect(model.setAside.report.contains(stray.lastPathComponent), "the share carries the file name")
    #expect(!model.setAside.exceedsBound)
    let moved = directory.appending(path: "quarantine").appending(path: stray.lastPathComponent)
    #expect(FileManager.default.fileExists(atPath: moved.path), "kept, not deleted")
  }

  @Test("a pile of set-aside files is flagged, by count or by size, but still only reported")
  func setAsideBound() {
    let file = SetAsideFile(url: URL(fileURLWithPath: "/in-memory/a.m4a"), byteCount: 1, modifiedAt: nil)
    #expect(!SetAsideSummary(recordings: Array(repeating: file, count: SetAsideSummary.countBound)).exceedsBound)
    #expect(SetAsideSummary(recordings: Array(repeating: file, count: SetAsideSummary.countBound + 1)).exceedsBound)
    let big = SetAsideFile(url: file.url, byteCount: SetAsideSummary.byteBound + 1, modifiedAt: nil)
    #expect(SetAsideSummary(queueFiles: [big]).exceedsBound)
  }

  @Test("a queued server delete shows as a row, and stopping it drops only the attempt")
  func queuedDeleteRow() async throws {
    let client = FakeAPIClient(now: { MemoFactory.now })
    let rig = OutboxRig(client: client)
    let session = try await rig.stack.session()
    let id = try await session.start(TakeRequest(mode: "auto", title: "Voice memo"))
    await rig.capture.recordWithoutClock(seconds: 12)
    #expect(await waitFor { await rig.created.memo(id: id.wireID) != nil }, "the server has the memo")
    await client.enqueueFailure(.unauthorized, for: .deleteMemo)

    await session.cancel()
    #expect(
      await waitFor { await rig.service.queuedItems().contains { $0.kind == .removal && $0.title == "Voice memo" } },
      "the pending delete is a row of the queue")

    await rig.service.discard(id: id.wireID)  // "Stop trying"
    #expect(await rig.service.queuedItems().isEmpty)
    await rig.clock.advance(by: 600)
    try await Task.sleep(for: .milliseconds(100))
    let deletes = await client.calls.filter { $0 == .deleteMemo(id: id.wireID) }
    #expect(deletes.count == 1, "nothing retries a delete the user stopped")
  }
}

/// An unreadable file that moves aside, after which the store still cannot be opened.
private actor MovesThenFailsStore: OutboxStore {
  struct StillBroken: Error {}
  private var moved = false

  func load() async throws -> OutboxRecord { throw moved ? StillBroken() : OutboxStoreError.undecodable }
  func save(_ record: OutboxRecord) async throws {}
  func quarantine() async throws -> URL? {
    moved = true
    return URL(fileURLWithPath: "/in-memory/outbox.quarantined-1.json")
  }
  func quarantined() async -> [URL] { moved ? [URL(fileURLWithPath: "/in-memory/outbox.quarantined-1.json")] : [] }
}

private struct FailingStore: OutboxStore {
  struct Unreadable: Error {}
  func load() async throws -> OutboxRecord { throw Unreadable() }
  func save(_ record: OutboxRecord) async throws {}
}

/// An unreadable file that cannot be moved.
private struct UnmovableStore: OutboxStore {
  func load() async throws -> OutboxRecord { throw OutboxStoreError.undecodable }
  func save(_ record: OutboxRecord) async throws {}
  func quarantine() async throws -> URL? { throw CocoaError(.fileWriteNoPermission) }
}

/// An unreadable file whose move waits until the test lets it finish, so a second reset can arrive in the middle of it.
private actor SlowQuarantineStore: OutboxStore {
  private var isUnreadable = true
  private(set) var moves = 0
  private var movingSignal: CheckedContinuation<Void, Never>?
  private var isMoving = false
  private var release: CheckedContinuation<Void, Never>?
  private var released = false

  func load() throws -> OutboxRecord {
    if isUnreadable { throw OutboxStoreError.undecodable }
    return OutboxRecord()
  }

  func save(_ record: OutboxRecord) throws {
    if isUnreadable { throw OutboxStoreError.undecodable }
  }

  func quarantine() async throws -> URL? {
    guard isUnreadable else { return nil }
    moves += 1
    isMoving = true
    movingSignal?.resume()
    movingSignal = nil
    if !released { await withCheckedContinuation { release = $0 } }
    isUnreadable = false
    return URL(fileURLWithPath: "/in-memory/outbox.quarantined-1.json")
  }

  func quarantined() -> [URL] { isUnreadable ? [] : [URL(fileURLWithPath: "/in-memory/outbox.quarantined-1.json")] }

  func waitUntilMoving() async {
    if isMoving { return }
    await withCheckedContinuation { movingSignal = $0 }
  }

  func finishMoving() {
    released = true
    release?.resume()
    release = nil
  }
}
