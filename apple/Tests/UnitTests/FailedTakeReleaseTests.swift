import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import Iris

/// Wave 19 I1: a take that fails on its own and is never stopped or cancelled lets go of `captureActive` once its recorder has
/// stopped, so spoken replies resume instead of waiting for a Stop that may never come.
@MainActor
@Suite("A failed take releases playback")
struct FailedTakeReleaseTests {
  let client = FakeAPIClient(now: { MemoFactory.now })

  private func waitFor(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<1_000 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  private func controller(_ rig: OutboxRig) -> TakeController {
    TakeController(
      stack: rig.stack,
      liveActivity: TakeLiveActivityCoordinator(
        activity: RecordingLiveActivity(), stack: rig.stack, created: rig.created),
      outbox: rig.service, microphone: nil, canRecord: true, isConfigured: { true }, requestPermission: { true })
  }

  @Test("the recorder fails, nobody stops the take: captureActive clears and the take still waits for the user")
  func failureReleasesTheClaim() async throws {
    let rig = OutboxRig(client: client)
    let controller = controller(rig)
    let model = TakeModel(controller: controller)
    let following = Task { await model.run() }
    defer { following.cancel() }

    try await controller.start(mode: .auto)
    #expect(controller.captureActive, "a recording take holds the claim")

    await rig.capture.recordWithoutClock(seconds: 12)
    await rig.capture.recorder.fail(reason: "engine restart failed")

    #expect(await waitFor { !controller.captureActive }, "the failed take let go of the microphone")
    #expect(model.state.phase == .failed, "and is still there for the user to stop or discard")
    #expect(model.state.recorderReleased)

    // The user's own stop afterwards is unaffected.
    #expect(try await controller.stop() != nil)
    #expect(!controller.captureActive)
  }

  @Test("a take that is recording keeps the claim")
  func recordingKeepsTheClaim() async throws {
    let rig = OutboxRig(client: client)
    let controller = controller(rig)
    let model = TakeModel(controller: controller)
    let following = Task { await model.run() }
    defer { following.cancel() }

    try await controller.start(mode: .auto)
    await rig.capture.recordWithoutClock(seconds: 12)
    try await Task.sleep(for: .milliseconds(100))

    #expect(controller.captureActive)
    try await controller.cancel()
  }
}
