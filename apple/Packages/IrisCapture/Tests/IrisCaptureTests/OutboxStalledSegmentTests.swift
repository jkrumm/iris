import Foundation
import Testing

@testable import IrisCapture

/// A segment refused for good (the server was restarting when its `PUT` landed) stalls, but the take must not wait for a
/// person: `complete` goes out without it, the server names the segment (422 `missing_segments`) and the outbox sends it
/// again with a fresh attempt count.
struct OutboxStalledSegmentTests {
  private let id = memo(2)

  private func key(_ index: Int) -> SegmentKey { SegmentKey(memoID: id, index: index) }

  private func finishedTake(segments: Int, refusing index: Int, times: Int) async throws -> OutboxHarness {
    let harness = try await OutboxHarness()
    await harness.uploader.checkCompletesAgainstUploads()
    await harness.uploader.refuseNext(times, for: key(index))
    var item = voiceItem(id)
    item.create = .pending
    #expect(try await harness.outbox.enqueueItem(item))
    for position in 0..<segments { await harness.outbox.enqueue(segment(id, position)) }
    await harness.outbox.finishMemo(id, segmentCount: segments)
    return harness
  }

  private func isStalled(_ harness: OutboxHarness) async throws -> Bool {
    let row = try #require(await harness.outbox.queue().first)
    guard case .failed(let retryAt, _) = row.status else { return false }
    return retryAt == nil
  }

  @Test func aTakeWhoseSegmentWasRefusedStillCompletesAndSendsItAgain() async throws {
    let harness = try await finishedTake(segments: 3, refusing: 1, times: 1)
    await harness.outbox.settled()

    // Segment 1 stalled; 0 and 2 are up. `complete` went out anyway, was refused naming 1, and 1 was sent again.
    #expect(await harness.uploader.completeAttempts == 1, "complete is not held back by the stalled segment")
    #expect(await harness.uploader.attempts[key(1)] == 2, "the refused segment went up again")
    #expect(await harness.uploader.completed.isEmpty)

    await harness.clock.advance(by: 10)  // past the backoff
    await harness.outbox.settled()

    #expect(await harness.uploader.completed == [.init(memoID: id, segmentCount: 3)])
    #expect(await harness.uploader.uploaded.sorted { $0.index < $1.index }.map(\.index) == [0, 1, 2])
    #expect(await harness.outbox.queue().isEmpty)
    await harness.outbox.shutdown()
  }

  @Test func aSegmentTheServerKeepsRefusingEndsInAStallNotALoop() async throws {
    let harness = try await finishedTake(segments: 2, refusing: 0, times: 1_000)
    for _ in 0..<60 {
      await harness.outbox.settled()
      await harness.clock.advance(by: 400)
    }
    await harness.outbox.settled()

    #expect(await harness.uploader.completed.isEmpty)
    #expect(try await isStalled(harness), "visible, waiting for retry now or discard")
    #expect(await harness.uploader.completeAttempts <= OutboxPolicy().maxAttempts, "the completions are capped")
    await harness.outbox.shutdown()
  }

  @Test func completeStillWaitsForASegmentThatIsBackingOff() async throws {
    let harness = try await OutboxHarness()
    await harness.uploader.failNext(1, for: key(1))  // a plain failure: backs off, not stalled
    var item = voiceItem(id)
    item.create = .pending
    #expect(try await harness.outbox.enqueueItem(item))
    for position in 0..<2 { await harness.outbox.enqueue(segment(id, position)) }
    await harness.outbox.finishMemo(id, segmentCount: 2)
    await harness.outbox.settled()

    #expect(await harness.uploader.completeAttempts == 0, "no complete while a segment may still go up on its own")
    await harness.outbox.shutdown()
  }
}
