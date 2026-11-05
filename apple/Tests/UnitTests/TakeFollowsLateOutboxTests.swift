import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import Iris

/// A store that cannot be read for its first `failures` loads (an unreadable file at launch, before the first unlock), then works.
private actor LateStore: OutboxStore {
  struct Unreadable: Error {}

  private var failures: Int
  private var record = OutboxRecord()

  init(failures: Int) {
    self.failures = failures
  }

  func load() throws -> OutboxRecord {
    if failures > 0 {
      failures -= 1
      throw Unreadable()
    }
    return record
  }

  func save(_ record: OutboxRecord) {
    self.record = record
  }
}

/// Wave 20 I1: the take screen follows the capture session even when the outbox opens after the app has started following.
@MainActor
@Suite("The take follows an outbox that opens late")
struct TakeFollowsLateOutboxTests {
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
      outbox: rig.service, microphone: nil, canRecord: true, isConfigured: { true }, requestPermission: { true },
      preview: nil)
  }

  @Test("the queue opens after the follower started: a take then shows on the take screen, with its levels")
  func followsAfterTheQueueOpens() async throws {
    let rig = OutboxRig(client: client, store: LateStore(failures: 1))
    let controller = controller(rig)
    let model = TakeModel(controller: controller)
    let following = Task { await model.run() }
    defer { following.cancel() }

    // The follower's first look found the queue closed (the first load failed). Nothing opened it since.
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.state.phase == .idle)

    // The queue opens (Reset outbox, the first unlock, a refresh all end up here) and a take starts.
    await rig.service.resume()
    try await controller.start(mode: .hermes)

    #expect(await waitFor { model.state.phase == .recording && model.showsFull }, "the update reached the take screen")
    for _ in 0..<200 where model.levels.last != 0.5 {
      await rig.capture.recordWithoutClock(seconds: 1)
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.levels.last == 0.5, "and so did the level meter")

    try await controller.cancel()
    #expect(await waitFor { model.state.phase == .idle })
  }

  @Test("a stack that never opens leaves the follower waiting, and cancelling it ends the wait")
  func neverOpensCancelsCleanly() async {
    let rig = OutboxRig(client: client, store: LateStore(failures: .max))
    let model = TakeModel(controller: controller(rig))
    let following = Task { await model.run() }
    try? await Task.sleep(for: .milliseconds(100))
    following.cancel()
    await following.value
    #expect(model.state.phase == .idle)
  }
}
