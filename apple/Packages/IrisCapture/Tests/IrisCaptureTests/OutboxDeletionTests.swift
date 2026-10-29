import Foundation
import Testing

@testable import IrisCapture

/// A take discarded after the server created its memo: the `DELETE` is queued, retried and survives a relaunch.
struct OutboxDeletionTests {
  @Test func discardingACreatedTakeDeletesItsMemoOnTheServer() async throws {
    let harness = try await OutboxHarness()
    let id = memo(1)
    try await harness.outbox.enqueueItem(voiceItem(id))
    await harness.outbox.enqueue(segment(id, 0))
    await harness.outbox.settled()
    #expect(await harness.uploader.created.map(\.memoID) == [id])

    await harness.outbox.discard(id)
    await harness.outbox.settled()

    #expect(await harness.uploader.deleted == [id])
    #expect(await harness.outbox.queue().isEmpty)
    #expect(await harness.store.load().deletions.isEmpty, "an acknowledged delete leaves nothing behind")
    #expect(await harness.outbox.wasDiscarded(id))
    await harness.outbox.shutdown()
  }

  @Test func aTakeThatWasNeverCreatedSendsNoDelete() async throws {
    let harness = try await OutboxHarness()
    let id = memo(1)
    try await harness.outbox.enqueueItem(voiceItem(id))
    await harness.outbox.settled()
    #expect(await harness.uploader.created.isEmpty, "a take is created with its first segment")

    await harness.outbox.discard(id)
    await harness.outbox.settled()

    #expect(await harness.uploader.deleteAttempts == 0)
    #expect(await harness.store.load().deletions.isEmpty)
    await harness.outbox.shutdown()
  }

  @Test func aRefusedCreateAndATextItemSendNoDelete() async throws {
    let harness = try await OutboxHarness()
    await harness.uploader.failNextCreates(1, permanent: true)
    try await harness.outbox.enqueueItem(voiceItem(memo(1)))
    await harness.outbox.enqueue(segment(memo(1), 0))
    await harness.outbox.settled()
    try await harness.outbox.enqueueItem(textItem(memo(2)))
    await harness.outbox.settled()

    await harness.outbox.discard(memo(1))
    await harness.outbox.discard(memo(2))
    await harness.outbox.settled()

    // A 409 on create can mean another device's memo owns the id: it is not ours to delete.
    #expect(await harness.uploader.deleteAttempts == 0)
    await harness.outbox.shutdown()
  }

  @Test func theDeleteIsRetriedWithBackoffUntilTheServerAnswers() async throws {
    let harness = try await OutboxHarness()
    let id = memo(1)
    try await harness.outbox.enqueueItem(voiceItem(id))
    await harness.outbox.enqueue(segment(id, 0))
    await harness.outbox.settled()
    await harness.uploader.failNextDeletes(2)

    await harness.outbox.discard(id)
    await harness.outbox.settled()
    #expect(await harness.uploader.deleteAttempts == 1)
    #expect(await harness.store.load().deletions.count == 1, "kept until acknowledged")

    await harness.clock.advance(by: 2)
    await harness.outbox.settled()
    await harness.clock.advance(by: 4)
    await harness.outbox.settled()

    #expect(await harness.uploader.deleted == [id])
    #expect(await harness.store.load().deletions.isEmpty)
    await harness.outbox.shutdown()
  }

  @Test func aPendingDeleteSurvivesARelaunch() async throws {
    let first = try await OutboxHarness()
    let id = memo(1)
    try await first.outbox.enqueueItem(voiceItem(id))
    await first.outbox.enqueue(segment(id, 0))
    await first.outbox.settled()
    await first.uploader.failNextDeletes(1)
    await first.outbox.discard(id)
    await first.outbox.settled()
    await first.outbox.shutdown()

    let second = try await OutboxHarness(record: await first.store.load())
    await second.outbox.resume()
    await second.clock.advance(by: 2)
    await second.outbox.settled()

    #expect(await second.uploader.deleted == [id])
    await second.outbox.shutdown()
  }

  @Test func aDeleteTheServerKeepsRefusingStallsInTheQueueInsteadOfVanishing() async throws {
    let harness = try await OutboxHarness()
    let id = memo(1)
    try await harness.outbox.enqueueItem(voiceItem(id))
    await harness.outbox.enqueue(segment(id, 0))
    await harness.outbox.settled()
    await harness.uploader.failNextDeletes(1, permanent: true)

    await harness.outbox.discard(id)
    await harness.outbox.settled()

    #expect(await harness.uploader.deleteAttempts == 1)
    #expect(await harness.store.load().deletions.map(\.memoID) == [id], "kept, not dropped")
    let row = try #require(await harness.outbox.queue().first)
    #expect(row.isDeletion && row.id == id)
    #expect(row.item.title == "Voice memo", "the row names the discarded take")
    #expect(row.status == .failed(retryAt: nil, reason: "not deletable"), "a stall is visible with its reason")

    // "Retry now" sends it again and the acknowledged delete leaves the queue.
    await harness.outbox.retryNow(id)
    await harness.outbox.settled()
    #expect(await harness.uploader.deleted == [id])
    #expect(await harness.outbox.queue().isEmpty)
    #expect(await harness.store.load().deletions.isEmpty)
    await harness.outbox.shutdown()
  }

  @Test func theUserCanStopTryingToDeleteAStalledMemo() async throws {
    let harness = try await OutboxHarness()
    let id = memo(1)
    try await harness.outbox.enqueueItem(voiceItem(id))
    await harness.outbox.enqueue(segment(id, 0))
    await harness.outbox.settled()
    await harness.uploader.failNextDeletes(1, permanent: true)
    await harness.outbox.discard(id)
    await harness.outbox.settled()
    #expect(await harness.outbox.queue().count == 1)

    await harness.outbox.abandonDeletion(id)

    #expect(await harness.outbox.queue().isEmpty)
    #expect(await harness.store.load().deletions.isEmpty)
    await harness.outbox.shutdown()
  }

  @Test func aStalledDeleteWaitsForTheUserAndNoTimerSendsIt() async throws {
    let harness = try await OutboxHarness(policy: OutboxPolicy(maxAttempts: 2, jitter: { 0 }))
    let id = memo(1)
    try await harness.outbox.enqueueItem(voiceItem(id))
    await harness.outbox.enqueue(segment(id, 0))
    await harness.outbox.settled()
    await harness.uploader.failNextDeletes(5, permanent: true)

    await harness.outbox.discard(id)
    await harness.outbox.settled()
    #expect(await harness.outbox.queue().first?.status == .failed(retryAt: nil, reason: "not deletable"))
    await harness.clock.advance(by: 600)
    await harness.outbox.settled()
    #expect(await harness.uploader.deleteAttempts == 1, "a stalled delete waits for the user, no timer sends it")
    await harness.outbox.shutdown()
  }

  /// The create was on the wire when the app died: the relaunch resets it to pending, and the server may have the memo.
  @Test func aTakeWhoseCreateWasOnTheWireWhenTheAppDiedIsDeletedOnDiscard() async throws {
    let id = memo(1)
    var item = voiceItem(id)
    item.create = .uploading
    item.createMayHaveLanded = true
    let record = OutboxRecord(
      entries: [OutboxEntry(segment: segment(id, 0), sequence: 0, state: .pending, attempts: 0)], items: [item],
      nextSequence: 1)
    let relaunched = try await OutboxHarness(record: record)

    await relaunched.outbox.discard(id)
    await relaunched.outbox.settled()

    #expect(await relaunched.uploader.deleted == [id], "it must not stay `receiving` on the server")
    #expect(await relaunched.uploader.created.isEmpty, "the discarded take is not created again")
    await relaunched.outbox.shutdown()
  }

  @Test func aCreateCutOffByShutdownMayHaveLandedAndIsDeletedOnDiscard() async throws {
    let first = try await OutboxHarness()
    let id = memo(1)
    try await first.outbox.enqueueItem(voiceItem(id))
    await first.outbox.enqueue(segment(id, 0))
    await first.outbox.settled()
    // A second life of the same record: the item is `uploaded` there, so rebuild the cut-off state by hand.
    var saved = await first.store.load()
    saved.items[0].create = .pending
    #expect(saved.items[0].createMayHaveLanded, "handing the create out marks it")
    await first.outbox.shutdown()

    let second = try await OutboxHarness(record: saved)
    await second.outbox.discard(id)
    await second.outbox.settled()
    #expect(await second.uploader.deleted == [id])
    await second.outbox.shutdown()
  }

  @Test func aCreateThatWasNeverHandedOutIsNotDeleted() async throws {
    let id = memo(1)
    let record = OutboxRecord(
      entries: [OutboxEntry(segment: segment(id, 0), sequence: 0, state: .pending, attempts: 0)],
      items: [voiceItem(id)], nextSequence: 1)
    let relaunched = try await OutboxHarness(record: record)

    await relaunched.outbox.discard(id)
    await relaunched.outbox.settled()

    #expect(await relaunched.uploader.deleteAttempts == 0)
    await relaunched.outbox.shutdown()
  }

  @Test func aRecordWithoutTheCreateFlagReadsItFromTheCreateState() throws {
    let id = memo(1)
    for (state, expected): (OutboxState, Bool) in [
      (.pending, false), (.stalled, false), (.uploading, true), (.uploaded, true),
    ] {
      var item = voiceItem(id)
      item.create = state
      var json = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
      json["createMayHaveLanded"] = nil
      let decoded = try JSONDecoder().decode(OutboxItem.self, from: JSONSerialization.data(withJSONObject: json))
      #expect(decoded.createMayHaveLanded == expected, "\(state)")
    }
  }

  @Test func theDeleteWaitsForACreateThatIsStillOnTheWire() async throws {
    let harness = try await OutboxHarness()
    let id = memo(1)
    try await harness.outbox.enqueueItem(voiceItem(id))
    await harness.outbox.enqueue(segment(id, 0))
    await harness.outbox.settled()

    await harness.outbox.discard(id)
    await harness.outbox.settled()

    let log = await harness.uploader.log
    #expect(log.first == "create")
    #expect(log.last == "delete")
    await harness.outbox.shutdown()
  }

  /// A kill after Discard returned: the relaunch loads what the store held at that moment. The take is still unfinished
  /// there (no `complete` record), which is exactly what `recoverUnfinishedTakes` finishes after a crash, so the discard must
  /// already have taken the item and its segments out of the saved record.
  @Test func aRelaunchRightAfterADiscardDoesNotCompleteTheDiscardedTake() async throws {
    let first = try await OutboxHarness()
    let id = memo(1)
    try await first.outbox.enqueueItem(voiceItem(id))
    await first.outbox.enqueue(segment(id, 0))
    await first.outbox.enqueue(segment(id, 1))
    await first.outbox.settled()
    await first.outbox.discard(id)

    let saved = await first.store.load()
    #expect(saved.items.isEmpty && saved.entries.isEmpty && saved.memos.isEmpty)
    #expect(saved.deletions.map(\.memoID) == [id])

    let second = try await OutboxHarness(record: saved)
    await second.outbox.settled()
    #expect(await second.outbox.queue().isEmpty)
    #expect(await second.uploader.completed.isEmpty, "the discarded take is not finished and sent")
    #expect(await second.uploader.uploaded.isEmpty)
    #expect(await second.uploader.deleted == [id], "its memo is deleted instead")
    await first.outbox.shutdown()
    await second.outbox.shutdown()
  }

  @Test func aRelaunchRightAfterDiscardingATakeTheServerNeverGotSendsNothing() async throws {
    let first = try await OutboxHarness()
    let id = memo(1)
    await first.uploader.failNextCreates(1, permanent: true)
    try await first.outbox.enqueueItem(voiceItem(id))
    await first.outbox.enqueue(segment(id, 0))
    await first.outbox.settled()
    await first.outbox.discard(id)

    let second = try await OutboxHarness(record: await first.store.load())
    await second.outbox.settled()
    #expect(await second.outbox.queue().isEmpty)
    #expect(await second.uploader.created.isEmpty)
    #expect(await second.uploader.completed.isEmpty)
    #expect(await second.uploader.deleteAttempts == 0)
    await first.outbox.shutdown()
    await second.outbox.shutdown()
  }

  @Test func theRecordWithoutDeletionsStillDecodes() throws {
    let json = #"{"entries":[],"memos":[],"nextSequence":0}"#
    let record = try JSONDecoder().decode(OutboxRecord.self, from: Data(json.utf8))
    #expect(record.deletions.isEmpty)
  }
}
