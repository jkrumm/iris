import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import Iris

/// The Live Activity's timer fields: counted from the start moved forward by the paused time, frozen while the recorder is
/// stopped (paused or failed), nil in the phases the server drives.
@MainActor
@Suite("Live Activity timer")
struct LiveActivityTimerTests {
  let client = FakeAPIClient(now: { MemoFactory.now })

  private func waitFor(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<1_000 {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
  }

  /// A clock the test moves by hand; the follower reads it on the main actor.
  private final class Instant: @unchecked Sendable {  // only read and set from the main actor in these tests
    var value: Date
    init(_ value: Date) { self.value = value }
  }

  @Test("paused carries the frozen instant, the resume shifts the start and unfreezes, a failure freezes again")
  func pauseResumeFail() async throws {
    let rig = OutboxRig(client: client)
    let activity = RecordingLiveActivity()
    let instant = Instant(Date(timeIntervalSince1970: 1_800_000_000))
    let coordinator = TakeLiveActivityCoordinator(
      activity: activity, stack: rig.stack, created: rig.created, now: { instant.value })
    let session = try await rig.stack.session()
    let id = try await session.start(TakeRequest(mode: "auto", title: "Voice memo"))
    let startedAt = try #require(await session.current.startedAt)
    await coordinator.begin(memoID: id, mode: .hermes, startedAt: startedAt)

    instant.value = instant.value.addingTimeInterval(10)
    let pausedInstant = instant.value
    await session.pause()
    #expect(await waitFor { activity.phases(of: id.wireID).last == .paused })
    let paused = try #require(activity.states.last)
    #expect(paused.timerFrozenAt == pausedInstant)
    #expect(paused.timerStart == startedAt)

    instant.value = instant.value.addingTimeInterval(30)
    await session.resume()
    let shifted = startedAt.addingTimeInterval(30)
    #expect(
      await waitFor { activity.states.last?.phase == .recording && activity.states.last?.timerStart == shifted })
    let resumed = try #require(activity.states.last)
    #expect(resumed.timerFrozenAt == nil)
    #expect(resumed.timerStart == shifted)

    instant.value = instant.value.addingTimeInterval(5)
    let failedInstant = instant.value
    await rig.capture.recorder.fail(reason: "segment write failed")
    await coordinator.finished()
    let final = try #require(activity.ends.first?.finalState)
    #expect(final.phase == .failed)
    #expect(final.timerFrozenAt == failedInstant)
    #expect(final.timerStart == shifted)
  }

  @Test("the uploading state carries no timer fields")
  func serverPhasesHaveNone() {
    let uploading = TakeLiveActivityCoordinator.state(.uploading, inputName: nil)
    #expect(uploading.timerStart == nil && uploading.timerFrozenAt == nil)
  }
}
