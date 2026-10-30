import Foundation
import Testing

@testable import IrisCapture

struct OutboxStateMachineTests {
  let t0 = Date(timeIntervalSince1970: 1_000_000)
  let policy = OutboxPolicy(maxConcurrentUploads: 2, baseDelay: 2, maxDelay: 300, jitterFraction: 0.25, jitter: { 0 })

  private func makeMachine(_ policy: OutboxPolicy? = nil) -> OutboxStateMachine {
    OutboxStateMachine(record: OutboxRecord(), policy: policy ?? self.policy)
  }

  @Test(arguments: [(1, 2.0), (2, 4.0), (3, 8.0), (4, 16.0), (8, 256.0), (9, 300.0), (60, 300.0)])
  func backoffDoublesAndCaps(attempt: Int, expected: Double) {
    #expect(policy.delay(forAttempt: attempt) == expected)
  }

  @Test(arguments: [(0.0, 2.0), (0.5, 2.25), (0.999, 2.4995)])
  func jitterAddsAFractionOfTheDelay(jitter: Double, expected: Double) {
    let jittered = OutboxPolicy(baseDelay: 2, jitterFraction: 0.25, jitter: { jitter })
    #expect(abs(jittered.delay(forAttempt: 1) - expected) < 0.0001)
  }

  @Test func enqueueIsIdempotentPerMemoAndIndex() {
    var machine = makeMachine()
    let accepted = [
      machine.enqueue(segment(memo(1), 0)),
      machine.enqueue(segment(memo(1), 0)),
      machine.enqueue(segment(memo(1), 1)),
      machine.enqueue(segment(memo(2), 0)),
    ]
    #expect(accepted == [true, false, true, true])
    #expect(machine.entries.count == 3)
  }

  @Test func dispatchHonoursTheCapAndOrdersByEnqueue() {
    var machine = makeMachine()
    for index in 0..<5 { machine.enqueue(segment(memo(1), index)) }

    let first = machine.dispatch(now: t0, inFlight: 0)
    #expect(first == [.upload(segment(memo(1), 0)), .upload(segment(memo(1), 1))])
    let actual1 = machine.dispatch(now: t0, inFlight: 2)
    #expect(actual1.isEmpty)

    machine.uploadSucceeded(SegmentKey(memoID: memo(1), index: 0))
    let actual2 = machine.dispatch(now: t0, inFlight: 1)
    #expect(actual2 == [.upload(segment(memo(1), 2))])
  }

  @Test func failureSchedulesARetryAndDispatchWaitsForIt() {
    var machine = makeMachine()
    machine.enqueue(segment(memo(1), 0))
    _ = machine.dispatch(now: t0, inFlight: 0)
    let key = SegmentKey(memoID: memo(1), index: 0)
    machine.uploadFailed(key, now: t0)

    #expect(machine.entries[key]?.state == .failed(retryAt: t0.addingTimeInterval(2)))
    #expect(machine.entries[key]?.attempts == 1)
    #expect(machine.nextWake(after: t0) == t0.addingTimeInterval(2))
    let actual1 = machine.dispatch(now: t0.addingTimeInterval(1.9), inFlight: 0)
    #expect(actual1.isEmpty)
    let actual2 = machine.dispatch(now: t0.addingTimeInterval(2), inFlight: 0)
    #expect(actual2 == [.upload(segment(memo(1), 0))])
    #expect(machine.nextWake(after: t0.addingTimeInterval(2)) == nil)
  }

  @Test func completeIsHandedOutOnlyWhenEverySegmentIsUploaded() {
    var machine = makeMachine()
    machine.enqueue(segment(memo(1), 0))
    machine.enqueue(segment(memo(1), 1))
    machine.finishMemo(memo(1), segmentCount: 2)

    _ = machine.dispatch(now: t0, inFlight: 0)
    machine.uploadSucceeded(SegmentKey(memoID: memo(1), index: 0))
    let actual1 = machine.dispatch(now: t0, inFlight: 1)
    #expect(actual1.isEmpty)  // segment 1 still uploading

    machine.uploadSucceeded(SegmentKey(memoID: memo(1), index: 1))
    let actual2 = machine.dispatch(now: t0, inFlight: 0)
    #expect(actual2 == [.complete(memo(1), segmentCount: 2)])
    let actual3 = machine.dispatch(now: t0, inFlight: 0)
    #expect(actual3.isEmpty)  // not handed out twice

    machine.completeSucceeded(memo(1))
    #expect(machine.record == OutboxRecord(nextSequence: 2, completedMemos: [memo(1)]))
  }

  @Test func handingOutCompleteIsRememberedAcrossARelaunchAndRevertGivesItBack() {
    var machine = makeMachine()
    machine.enqueue(segment(memo(1), 0))
    machine.finishMemo(memo(1), segmentCount: 1)
    _ = machine.dispatch(now: t0, inFlight: 0)
    machine.uploadSucceeded(SegmentKey(memoID: memo(1), index: 0))
    #expect(machine.record.memos.first?.completeMayHaveLanded == nil, "nothing sent yet")

    let work = machine.dispatch(now: t0, inFlight: 0)
    #expect(work == [.complete(memo(1), segmentCount: 1)])
    #expect(machine.record.memos.first?.completeMayHaveLanded == true)
    let relaunched = OutboxStateMachine(record: machine.record, policy: policy)
    #expect(relaunched.record.memos.first?.completeMayHaveLanded == true, "an in-flight complete may have landed")

    // The dispatch could not be saved, so nothing was sent: the memo is as it was.
    machine.revertDispatch(work)
    #expect(machine.record.memos.first?.completeMayHaveLanded == nil)
  }

  @Test func completeWaitsForSegmentsThatWereNeverEnqueued() {
    var machine = makeMachine()
    machine.enqueue(segment(memo(1), 0))
    machine.finishMemo(memo(1), segmentCount: 2)
    _ = machine.dispatch(now: t0, inFlight: 0)
    machine.uploadSucceeded(SegmentKey(memoID: memo(1), index: 0))
    let actual = machine.dispatch(now: t0, inFlight: 0)
    #expect(actual.isEmpty)
  }

  @Test func aMemoWithoutSegmentsIsNotCompleted() {
    var machine = makeMachine()
    machine.finishMemo(memo(1), segmentCount: 0)
    #expect(machine.memos.isEmpty)
  }

  @Test func recordRoundTripsThroughJSON() throws {
    var machine = makeMachine()
    machine.enqueue(segment(memo(1), 0))
    machine.finishMemo(memo(1), segmentCount: 1)
    _ = machine.dispatch(now: t0, inFlight: 0)
    machine.uploadFailed(SegmentKey(memoID: memo(1), index: 0), now: t0)

    let data = try JSONEncoder().encode(machine.record)
    #expect(try JSONDecoder().decode(OutboxRecord.self, from: data) == machine.record)
  }

  @Test func relaunchReturnsUploadingToPendingAndKeepsFailures() {
    var original = makeMachine()
    original.enqueue(segment(memo(1), 0))
    original.enqueue(segment(memo(1), 1))
    original.enqueue(segment(memo(1), 2))
    _ = original.dispatch(now: t0, inFlight: 0)  // 0 and 1 uploading
    original.uploadFailed(SegmentKey(memoID: memo(1), index: 1), now: t0)

    let relaunched = OutboxStateMachine(record: original.record, policy: policy)
    #expect(relaunched.entries[SegmentKey(memoID: memo(1), index: 0)]?.state == .pending)
    #expect(
      relaunched.entries[SegmentKey(memoID: memo(1), index: 1)]?.state == .failed(retryAt: t0.addingTimeInterval(2)))
    #expect(relaunched.entries[SegmentKey(memoID: memo(1), index: 1)]?.attempts == 1)
    #expect(relaunched.entries[SegmentKey(memoID: memo(1), index: 2)]?.state == .pending)
  }

  @Test func repeatedFinishMemoAfterCompletionIsANoOp() {
    var machine = makeMachine()
    machine.enqueue(segment(memo(1), 0))
    machine.finishMemo(memo(1), segmentCount: 1)
    machine.completeSucceeded(memo(1))

    machine.finishMemo(memo(1), segmentCount: 1)
    #expect(machine.memos.isEmpty)
    #expect(machine.enqueue(segment(memo(1), 0)) == false)
    #expect(machine.entries.isEmpty)
    #expect(machine.dispatch(now: t0, inFlight: 0).isEmpty)
  }

  @Test func completedMemosSurviveARelaunchOfTheMachine() {
    var original = makeMachine()
    original.enqueue(segment(memo(1), 0))
    original.finishMemo(memo(1), segmentCount: 1)
    original.completeSucceeded(memo(1))

    var relaunched = OutboxStateMachine(record: original.record, policy: policy)
    relaunched.finishMemo(memo(1), segmentCount: 1)
    #expect(relaunched.memos.isEmpty)
    #expect(relaunched.record.completedMemos == [memo(1)])
  }

  @Test func completedMemoHistoryIsBounded() {
    var machine = makeMachine()
    let limit = OutboxStateMachine.completedMemoLimit
    for n in 0..<(limit + 5) {
      let id = MemoID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(n >> 16), UInt8((n >> 8) & 0xff), UInt8(n & 0xff), 1))
      machine.completeSucceeded(id)
    }
    #expect(machine.record.completedMemos.count == limit)
  }

  @Test func recordWrittenBeforeCompletedMemosExistedStillDecodes() throws {
    var machine = makeMachine()
    machine.enqueue(segment(memo(1), 0))
    machine.finishMemo(memo(1), segmentCount: 1)
    let data = try JSONEncoder().encode(machine.record)
    var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    json["completedMemos"] = nil

    let legacy = try JSONSerialization.data(withJSONObject: json)
    let decoded = try JSONDecoder().decode(OutboxRecord.self, from: legacy)
    #expect(decoded.completedMemos.isEmpty)
    #expect(decoded.entries == machine.record.entries)
    #expect(decoded.memos == machine.record.memos)
  }
}
