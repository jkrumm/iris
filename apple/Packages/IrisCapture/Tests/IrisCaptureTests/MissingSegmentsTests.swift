import Foundation
import Testing

@testable import IrisCapture

/// `complete` refused with 422 `missing_segments`: the server holds fewer segments than the phone sent. The files are still
/// here, so the listed segments go up again and `complete` follows, instead of a stall nobody can clear.
struct MissingSegmentsTests {
  private let id = memo(1)

  private func isStalled(_ harness: OutboxHarness) async throws -> Bool {
    let row = try #require(await harness.outbox.queue().first)
    guard case .failed(let retryAt, _) = row.status else { return false }
    return retryAt == nil
  }

  private func finishedTake(segments: Int, missing: [[Int]]) async throws -> OutboxHarness {
    let harness = try await OutboxHarness()
    // Before the take can finish: `finishMemo` starts the transfers, and a script installed after it is a race.
    await harness.uploader.failNextComplete(missing: missing)
    var item = voiceItem(id)
    item.create = .pending
    #expect(try await harness.outbox.enqueueItem(item))
    for index in 0..<segments { await harness.outbox.enqueue(segment(id, index)) }
    await harness.outbox.finishMemo(id, segmentCount: segments)
    return harness
  }

  @Test func theSegmentsTheServerLacksAreSentAgainAndCompleteFollows() async throws {
    let harness = try await finishedTake(segments: 3, missing: [[1]])
    await harness.outbox.settled()
    // The refused segment goes up again at once; `complete` waits out its backoff.
    #expect(await harness.uploader.uploaded.filter { $0.index == 1 }.count == 2, "index 1 went up again")
    #expect(await harness.uploader.completed.isEmpty, "the first complete was refused")

    await harness.clock.advance(by: 10)  // past the backoff
    await harness.outbox.settled()

    let uploaded = await harness.uploader.uploaded
    #expect(uploaded.filter { $0.index == 1 }.count == 2, "and only once more")
    #expect(uploaded.filter { $0.index == 0 }.count == 1 && uploaded.filter { $0.index == 2 }.count == 1)
    #expect(await harness.uploader.completed == [.init(memoID: id, segmentCount: 3)])
    #expect(await harness.outbox.queue().isEmpty)
    await harness.outbox.shutdown()
  }

  @Test func aServerThatKeepsLosingThemStallsInsteadOfLooping() async throws {
    let harness = try await finishedTake(segments: 1, missing: Array(repeating: [0], count: 50))
    for _ in 0..<40 {
      await harness.outbox.settled()
      await harness.clock.advance(by: 400)
    }
    await harness.outbox.settled()

    #expect(await harness.uploader.completed.isEmpty)
    #expect(try await isStalled(harness), "stalled: it waits for retry now or discard")
    await harness.outbox.shutdown()
  }

  @Test func anIndexThatIsNotOursIsTheRefusalItWas() async throws {
    let harness = try await finishedTake(segments: 2, missing: [[7]])
    await harness.outbox.settled()

    #expect(try await isStalled(harness), "nothing to send again: stalled at once")
    await harness.outbox.shutdown()
  }
}
