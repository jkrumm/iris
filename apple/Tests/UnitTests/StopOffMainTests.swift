import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import Iris

/// A recorder whose `stop()` does not return until the test lets it, as a stuck engine does on a phone.
private struct HangingStopRecorder: SegmentRecorder {
  let base: FakeSegmentRecorder
  let gate: AsyncStream<Void>

  var events: AsyncStream<CaptureEvent> { base.events }
  var levels: AsyncStream<Float> { base.levels }

  func start(memoID: MemoID) async throws { try await base.start(memoID: memoID) }
  func stop() async throws {
    for await _ in gate { break }
    try await base.stop()
  }
  func rotate(for reason: RotationReason) async { await base.rotate(for: reason) }
  func pause() async { await base.pause() }
  func resume() async { await base.resume() }
}

/// Wave 17 I9: the device's Stop from the banner ended in a 10 s watchdog kill and a tail segment left behind. Stopping a take
/// only ever suspends the main actor; it never holds it, however long the recorder takes.
@MainActor
@Suite("Stop off the main thread")
struct StopOffMainTests {
  let client = FakeAPIClient(now: { MemoFactory.now })

  @Test("a recorder that never stops leaves the main actor free, and the take is finished with what closed")
  func hungRecorderStop() async throws {
    let (gate, release) = AsyncStream<Void>.makeStream()
    let rig = OutboxRig(client: client) { HangingStopRecorder(base: $0, gate: gate) }
    let coordinator = TakeLiveActivityCoordinator(
      activity: RecordingLiveActivity(), stack: rig.stack, created: rig.created)
    let model = TakeModel(
      controller: TakeController(
        stack: rig.stack, liveActivity: coordinator, outbox: rig.service, microphone: nil, canRecord: true,
        isConfigured: { true }, requestPermission: { true }))
    let follower = Task { await model.run() }
    defer {
      follower.cancel()
      release.finish()
    }
    await model.start()
    await rig.capture.recordWithoutClock(seconds: 12)  // one closed segment, then the stop hangs
    #expect(await waitUntil { model.isActive })

    let stopping = Task { await model.stop() }
    #expect(await waitUntil { model.isEnding && model.state.phase == .stopping })

    // The main actor serves other work while the stop is pending: ticks keep coming and a second Stop returns at once.
    var ticks = 0
    for _ in 0..<20 {
      try await Task.sleep(for: .milliseconds(10))
      ticks += 1
    }
    let secondStop = await ContinuousClock().measure { await model.stop() }
    #expect(ticks == 20 && secondStop < .milliseconds(100))
    #expect(model.isEnding, "still waiting on the recorder")

    // The stop timeout and the grace period run out on the clock, not on the main actor.
    var steps = 0
    while model.isActive && steps < 500 {
      await rig.clock.advance(by: 11)
      try await Task.sleep(for: .milliseconds(10))
      steps += 1
    }
    await stopping.value
    #expect(!model.isActive && !model.isEnding)

    // `stop()` has returned, the memo is still open for the tail: the grace period ends it with what closed.
    var drained = false
    for _ in 0..<500 where !drained {
      await rig.clock.advance(by: 11)
      drained = await rig.drain(seconds: 0.05)
    }
    #expect(drained, "the memo, finished with its closed segment, reaches the server")
  }

  private func waitUntil(seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<Int(seconds * 100) {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }
}
