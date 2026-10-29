import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import Iris

private func waitFor(seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
  for _ in 0..<Int(seconds * 100) {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return await condition()
}

private func stack(store: any OutboxStore, captureDirectory: URL? = nil) -> (CaptureStack, OutboxService) {
  let capture = FakeCapture(
    directory: FileManager.default.temporaryDirectory.appending(path: "iris-reset-\(UUID().uuidString)"))
  let created = CreatedMemoLog()
  let stack = CaptureStack(
    .init(
      session: capture.session, routes: capture.routes, recorder: capture.recorder, clock: ManualClock(), store: store,
      uploader: APIOutboxUploader(client: FakeAPIClient(), created: created), captureDirectory: captureDirectory))
  return (stack, OutboxService(stack: stack, created: created))
}

/// "Reset outbox": an outbox file that cannot be decoded is renamed aside and kept, and a fresh outbox opens.
@MainActor
@Suite("Outbox reset")
struct OutboxResetTests {
  @Test("an unreadable outbox is reported as such, not as a queue that is merely closed")
  func unreadable() async {
    let (stack, service) = stack(store: UnreadableOutboxStore())
    #expect(await stack.availability() == .unreadable)
    #expect(await service.isUnreadable())
    #expect(await !service.isAvailable())
    await #expect(throws: CaptureStackError.queueUnavailable) { try await stack.outbox() }
  }

  @Test("a queue that fails to load for another reason is unavailable, and a reset refuses to touch it")
  func notResettable() async {
    let (stack, service) = stack(store: FailingStore())
    #expect(await stack.availability() == .unavailable)
    #expect(await !service.resetOutbox())
    await #expect(throws: CaptureStackError.queueUnavailable) { try await stack.resetOutbox() }
  }

  @Test("the reset sets the file aside, opens a fresh outbox and accepts new work")
  func reset() async throws {
    let store = UnreadableOutboxStore()
    let (stack, service) = stack(store: store)
    #expect(await service.quarantinedFiles().isEmpty)

    #expect(await service.resetOutbox())

    #expect(await stack.availability() == .available)
    #expect(await service.queuedItems().isEmpty)
    #expect(await service.quarantinedFiles().count == 1, "the old file is kept, not deleted")
    let outcome = await service.submitText(
      TextSubmission(id: MemoID(), mode: .auto, text: "hello", threadId: nil, startedAt: Date()))
    #expect(outcome != .refused, "the fresh outbox takes new items")
    #expect(await !service.resetOutbox(), "a second reset has nothing to set aside")
  }

  @Test("Settings offers the reset only while the file is unreadable, and shows the set-aside file afterwards")
  func settings() async throws {
    let (_, service) = stack(store: UnreadableOutboxStore())
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
    let (_, service) = stack(store: UnmovableStore())
    let model = SettingsModel(client: FakeAPIClient(), queue: service)
    await model.load()
    #expect(model.queueUnreadable)

    await model.resetOutbox()

    #expect(model.resetFailed)
    #expect(model.queueUnreadable)
  }

  @Test("opening the outbox sweeps the capture directory: strays are moved aside, never deleted")
  func sweepAtOpen() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "iris-sweep-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stray = directory.appending(path: "\(UUID().uuidString)-0.m4a")
    try Data("half a take".utf8).write(to: stray)
    let (stack, _) = stack(store: InMemoryOutboxStore(), captureDirectory: directory)

    _ = try await stack.outbox()

    #expect(!FileManager.default.fileExists(atPath: stray.path))
    let moved = directory.appending(path: "quarantine").appending(path: stray.lastPathComponent)
    #expect(try Data(contentsOf: moved) == Data("half a take".utf8))
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
