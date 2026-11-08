import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import Iris

/// A Live Activity button names the take it was made for; one left over from an earlier take changes nothing.
@MainActor
@Suite("Live Activity controls of another take")
struct StaleTakeControlTests {
  let client = FakeAPIClient(now: { MemoFactory.now })

  private func controller(_ rig: OutboxRig) -> TakeController {
    TakeController(
      stack: rig.stack,
      liveActivity: TakeLiveActivityCoordinator(
        activity: RecordingLiveActivity(), stack: rig.stack, created: rig.created),
      outbox: rig.service, microphone: nil, canRecord: true, isConfigured: { true }, requestPermission: { true },
      preview: nil)
  }

  @Test("a stop or pause for another memo is ignored; one for the running memo, or without an id, acts")
  func controlsMatchTheRunningTake() async throws {
    let rig = OutboxRig(client: client)
    let controller = controller(rig)
    let session = try await rig.stack.session()
    let id = try await controller.start(mode: .hermes)

    await controller.togglePause(ifMemo: "some-older-memo")
    #expect(await session.current.phase == .recording, "a stale pause changes nothing")
    #expect(try await controller.stop(ifMemo: "some-older-memo") == nil)
    #expect(await session.current.phase == .recording, "a stale stop changes nothing")

    await controller.togglePause(ifMemo: id.wireID)
    #expect(await session.current.phase == .paused)
    await controller.togglePause(ifMemo: nil)
    #expect(await session.current.phase == .recording, "an activity without an id still works")

    try await controller.cancel()
  }
}
