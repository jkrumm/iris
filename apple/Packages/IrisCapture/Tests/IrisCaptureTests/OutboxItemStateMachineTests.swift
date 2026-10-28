import Foundation
import Testing

@testable import IrisCapture

struct OutboxItemStateMachineTests {
  let t0 = Date(timeIntervalSince1970: 1_000_000)
  let policy = OutboxPolicy(
    maxConcurrentUploads: 2, baseDelay: 2, maxDelay: 300, jitterFraction: 0.25, maxAttempts: 3, jitter: { 0 })

  private func machine(_ record: OutboxRecord = OutboxRecord()) -> OutboxStateMachine {
    OutboxStateMachine(record: record, policy: policy)
  }

  @Test func enqueueItemIsIdempotentPerMemoId() {
    var machine = machine()
    let r1 = machine.enqueueItem(textItem(memo(1)))
    #expect(r1)
    let r2 = machine.enqueueItem(textItem(memo(1), text: "another body"))
    #expect(!r2)
    #expect(machine.items.count == 1)
  }

  @Test func aTextItemIsCreatedThenForgotten() {
    var machine = machine()
    machine.enqueueItem(textItem(memo(1)))
    let work = machine.dispatch(now: t0, inFlight: 0)
    #expect(work.count == 1)
    guard case .create(let sent) = work.first else {
      Issue.record("expected a create")
      return
    }
    #expect(sent.memoID == memo(1))
    #expect(machine.queue().first?.status == .sending)

    machine.createSucceeded(memo(1))
    #expect(machine.items.isEmpty)
    // A repeat of the same id after it went through does not queue it again.
    let r3 = machine.enqueueItem(textItem(memo(1)))
    #expect(!r3)
  }

  @Test func aVoiceItemHoldsItsSegmentsAndCompletionBackUntilItIsCreated() {
    var machine = machine()
    machine.enqueueItem(voiceItem(memo(1)))
    machine.enqueue(segment(memo(1), 0))
    machine.finishMemo(memo(1), segmentCount: 1)

    let first = machine.dispatch(now: t0, inFlight: 0)
    #expect(first.count == 1, "only the create goes out")
    let r4 = machine.dispatch(now: t0, inFlight: 1)
    #expect(r4.isEmpty, "nothing else of the memo moves before the create")

    machine.createSucceeded(memo(1))
    #expect(machine.items[memo(1)]?.create == .uploaded)
    let r5 = machine.dispatch(now: t0, inFlight: 0)
    #expect(r5 == [.upload(segment(memo(1), 0))])
    machine.uploadSucceeded(SegmentKey(memoID: memo(1), index: 0))
    let r6 = machine.dispatch(now: t0, inFlight: 0)
    #expect(r6 == [.complete(memo(1), segmentCount: 1)])
    machine.completeSucceeded(memo(1))
    #expect(machine.items.isEmpty)
    #expect(machine.entries.isEmpty)
  }

  @Test func aTakeIsNotCreatedBeforeItHasASegmentOrEnded() {
    var machine = machine()
    machine.enqueueItem(voiceItem(memo(1)))
    #expect(machine.dispatch(now: t0, inFlight: 0).isEmpty, "a take that may still be cancelled stays off the server")

    machine.enqueue(segment(memo(1), 0))
    let withSegment = machine.dispatch(now: t0, inFlight: 0)
    #expect(withSegment.count == 1)

    var ended = self.machine()
    ended.enqueueItem(voiceItem(memo(2)))
    ended.finishMemo(memo(2), segmentCount: 1)
    #expect(ended.dispatch(now: t0, inFlight: 0).count == 1)
  }

  @Test func aFailedCreateBacksOffWithTheJitterFreeSchedule() {
    var machine = machine()
    machine.enqueueItem(textItem(memo(1)))
    _ = machine.dispatch(now: t0, inFlight: 0)
    machine.createFailed(memo(1), now: t0, reason: "offline")

    #expect(machine.items[memo(1)]?.create == .failed(retryAt: t0.addingTimeInterval(2)))
    #expect(machine.nextWake(after: t0) == t0.addingTimeInterval(2))
    let r7 = machine.dispatch(now: t0.addingTimeInterval(1), inFlight: 0)
    #expect(r7.isEmpty)
    let r8 = machine.dispatch(now: t0.addingTimeInterval(2), inFlight: 0)
    #expect(r8.count == 1)
    #expect(machine.queue().first?.status == .sending)
  }

  @Test func theQueueReportsTheRetryAndTheReasonOfAFailure() {
    var machine = machine()
    machine.enqueueItem(textItem(memo(1)))
    _ = machine.dispatch(now: t0, inFlight: 0)
    machine.createFailed(memo(1), now: t0, reason: "offline")
    #expect(machine.queue().first?.status == .failed(retryAt: t0.addingTimeInterval(2), reason: "offline"))
  }

  @Test func afterMaxAttemptsTheItemStallsAndNothingIsScheduled() {
    var machine = machine()
    machine.enqueueItem(textItem(memo(1)))
    var now = t0
    for _ in 0..<3 {
      let work = machine.dispatch(now: now, inFlight: 0)
      #expect(work.count == 1)
      machine.createFailed(memo(1), now: now)
      now = now.addingTimeInterval(1_000)
    }
    #expect(machine.items[memo(1)]?.create == .stalled)
    #expect(machine.nextWake(after: t0) == nil)
    let r9 = machine.dispatch(now: now, inFlight: 0)
    #expect(r9.isEmpty)
    #expect(machine.queue().first?.status == .failed(retryAt: nil, reason: nil))
  }

  @Test func aPermanentRefusalStallsAtOnce() {
    var machine = machine()
    machine.enqueueItem(textItem(memo(1)))
    _ = machine.dispatch(now: t0, inFlight: 0)
    machine.createFailed(memo(1), now: t0, permanent: true, reason: "thread is gone")
    #expect(machine.items[memo(1)]?.create == .stalled)
    #expect(machine.items[memo(1)]?.lastError == "thread is gone")
  }

  @Test func retryNowReArmsAStalledItemWithAFreshAttemptCount() {
    var machine = machine()
    machine.enqueueItem(textItem(memo(1)))
    _ = machine.dispatch(now: t0, inFlight: 0)
    machine.createFailed(memo(1), now: t0, permanent: true, reason: "refused")

    let r10 = machine.retryNow(memo(1))
    #expect(r10)
    #expect(machine.items[memo(1)]?.create == .pending)
    #expect(machine.items[memo(1)]?.attempts == 0)
    #expect(machine.items[memo(1)]?.lastError == nil)
    let r11 = machine.dispatch(now: t0, inFlight: 0)
    #expect(r11.count == 1)
    let r12 = machine.retryNow(memo(1))
    #expect(!r12, "an item that is in flight has nothing to retry")
  }

  @Test func retryNowAlsoReArmsAStalledSegmentAndCompletion() {
    var machine = machine()
    machine.enqueueItem(voiceItem(memo(1)))
    machine.enqueue(segment(memo(1), 0))
    machine.finishMemo(memo(1), segmentCount: 1)
    _ = machine.dispatch(now: t0, inFlight: 0)
    machine.createSucceeded(memo(1))
    _ = machine.dispatch(now: t0, inFlight: 0)
    let key = SegmentKey(memoID: memo(1), index: 0)
    machine.uploadFailed(key, now: t0, permanent: true, reason: "too large")
    #expect(machine.queue().first?.status == .failed(retryAt: nil, reason: "too large"))

    let r13 = machine.retryNow(memo(1))
    #expect(r13)
    #expect(machine.entries[key]?.state == .pending)
    #expect(machine.queue().first?.status == .waiting)
  }

  @Test func discardForgetsEverythingAndRefusesLateSegments() {
    var machine = machine()
    machine.enqueueItem(voiceItem(memo(1)))
    machine.enqueue(segment(memo(1), 0))
    machine.enqueue(segment(memo(1), 1))
    machine.enqueue(segment(memo(2), 0))

    let files = machine.discard(memo(1))
    #expect(files.count == 2)
    #expect(machine.items.isEmpty)
    #expect(machine.entries.keys.map(\.memoID) == [memo(2)])
    let r14 = machine.enqueue(segment(memo(1), 2))
    #expect(!r14, "a take still closing cannot bring the memo back")
    let r15 = machine.enqueueItem(voiceItem(memo(1)))
    #expect(!r15)
  }

  @Test func theQueueIsOldestFirstAndRecognisesARecordingTake() {
    var machine = machine()
    machine.enqueueItem(textItem(memo(2), queuedAt: t0.addingTimeInterval(10)))
    machine.enqueueItem(voiceItem(memo(1), queuedAt: t0))
    #expect(machine.queue().map(\.id) == [memo(1), memo(2)])
    #expect(machine.queue().map(\.status) == [.recording, .waiting])
    machine.finishMemo(memo(1), segmentCount: 1)
    #expect(machine.queue().first?.status == .waiting)
  }

  @Test func relaunchRestoresTheQueueAndPutsTransfersInFlightBackToPending() {
    var before = machine()
    before.enqueueItem(textItem(memo(1), text: "kept"))
    before.enqueueItem(textItem(memo(2), text: "failed"))
    _ = before.dispatch(now: t0, inFlight: 0)  // both create calls "in flight"
    before.createFailed(memo(2), now: t0, reason: "offline")

    let restored = machine(before.record)
    #expect(restored.items[memo(1)]?.create == .pending)
    #expect(restored.items[memo(2)]?.create == .failed(retryAt: t0.addingTimeInterval(2)))
    #expect(restored.items[memo(1)]?.kind == .text("kept"))
    #expect(restored.queue().map(\.id) == [memo(1), memo(2)])
  }

  @Test func relaunchFinishesATakeThatWasRecordingWithItsContiguousSegments() {
    var before = machine()
    before.enqueueItem(voiceItem(memo(1)))
    before.enqueue(segment(memo(1), 0))
    before.enqueue(segment(memo(1), 1))
    before.enqueue(segment(memo(1), 3))  // a hole: the take is what is contiguous from 0

    let restored = machine(before.record)
    #expect(restored.memos[memo(1)]?.segmentCount == 2)
    #expect(restored.queue().first?.status == .waiting)
  }

  @Test func relaunchDropsATakeThatNeverClosedASegment() {
    var before = machine()
    before.enqueueItem(voiceItem(memo(1)))
    #expect(machine(before.record).items.isEmpty)
  }

  @Test func aRecordWrittenBeforeItemsExistedStillDecodes() throws {
    let json = Data(#"{"entries":[],"memos":[],"nextSequence":4}"#.utf8)
    let record = try JSONDecoder().decode(OutboxRecord.self, from: json)
    #expect(record.items.isEmpty)
    #expect(record.nextSequence == 4)
  }

  @Test func theRecordRoundTripsThroughJSON() throws {
    var machine = machine()
    machine.enqueueItem(textItem(memo(1), text: "round trip", threadID: "thread-1"))
    _ = machine.dispatch(now: t0, inFlight: 0)
    machine.createFailed(memo(1), now: t0, permanent: true, reason: "refused")
    let data = try JSONEncoder().encode(machine.record)
    #expect(try JSONDecoder().decode(OutboxRecord.self, from: data) == machine.record)
  }
}
