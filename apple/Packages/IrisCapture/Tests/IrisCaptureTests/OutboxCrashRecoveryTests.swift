import Foundation
import Testing

@testable import IrisCapture

/// The app is killed while a `create` is on the wire: the request may have landed, and the queue file on disk is the state
/// from before the answer. The mechanism (TDD §4 "Outbox"): the dispatch is saved *before* the request goes out, with
/// `createMayHaveLanded`, so the disk always knows a create may exist; on relaunch an `uploading` create is pending again and
/// is re-sent (the server is idempotent per memo id), and a discard in between queues the server `DELETE`.
struct OutboxCrashRecoveryTests {
  /// Runs a take up to a create that is on the wire and never answered, and returns the queue file as the kill leaves it.
  private func killWithTheCreateOnTheWire(_ id: MemoID) async throws -> OutboxRecord {
    let first = try await OutboxHarness()
    await first.uploader.holdCreates()
    try await first.outbox.enqueueItem(voiceItem(id))
    await first.outbox.enqueue(segment(id, 0))
    await first.uploader.waitUntilCreateAttempts(1)
    let onDisk = await first.store.load()
    await first.outbox.shutdown()  // the process dies; the held request is never answered
    await first.uploader.releaseAll()
    return onDisk
  }

  @Test func theDiskKnowsTheCreateMayHaveLandedAndRelaunchSendsItAgain() async throws {
    let id = memo(1)
    let onDisk = try await killWithTheCreateOnTheWire(id)
    let item = try #require(onDisk.items.first)
    #expect(item.create == .uploading && item.createMayHaveLanded, "saved before the request went out")

    let second = try await OutboxHarness(record: onDisk)
    await second.outbox.resume()
    await second.outbox.settled()

    #expect(
      await second.uploader.created.map(\.memoID) == [id], "sent again: the server answers a repeat of the same memo id"
    )
    #expect(await second.uploader.uploaded.map(\.index) == [0])
    await second.outbox.shutdown()
  }

  @Test func aDiscardAfterTheKillDeletesTheMemoTheServerMayHave() async throws {
    let id = memo(1)
    let onDisk = try await killWithTheCreateOnTheWire(id)

    let second = try await OutboxHarness(record: onDisk)
    await second.outbox.discard(id)
    await second.outbox.settled()

    #expect(await second.uploader.deleted == [id], "the DELETE is queued from the flag that was saved before the send")
    #expect(await second.uploader.created.isEmpty, "and the create is not sent again")
    await second.outbox.shutdown()
  }
}
