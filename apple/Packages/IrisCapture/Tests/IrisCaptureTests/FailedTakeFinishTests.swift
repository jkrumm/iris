import Foundation
import Testing

@testable import IrisCapture

/// A recorder that failed and whose `stop()` then throws (or hangs): no last event comes, and the take must still go up.
private struct StopThrowsRecorder: SegmentRecorder {
  struct StopFailed: Error {}

  let base: FakeSegmentRecorder

  var events: AsyncStream<CaptureEvent> { base.events }
  var levels: AsyncStream<Float> { base.levels }

  func start(memoID: MemoID) async throws { try await base.start(memoID: memoID) }
  func stop() async throws { throw StopFailed() }
  func rotate(for reason: RotationReason) async { await base.rotate(for: reason) }
  func pause() async { await base.pause() }
  func resume() async { await base.resume() }
  func fail(reason: String) async { await base.fail(reason: reason) }
}

struct FailedTakeFinishTests {
  private let request = TakeRequest(mode: "auto", title: "Voice memo")

  private func waitForFailed(_ session: CaptureSession) async throws {
    for _ in 0..<400 where await session.current.phase != .failed { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await session.current.phase == .failed)
  }

  @Test func aFailedTakeWhoseStopThrowsIsFinishedWithWhatClosedWithoutWaitingForTheUser() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = try await OutboxHarness()
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let recorder = StopThrowsRecorder(base: fake.recorder)
    let session = CaptureSession(
      session: fake.session, routes: fake.routes, recorder: recorder, outbox: harness.outbox, clock: harness.clock)
    let id = try await session.start(request)
    await fake.record(seconds: 12)  // one closed segment, 2 s in the open one
    await recorder.fail(reason: "engine restart failed")
    try await waitForFailed(session)

    // The phase flips to failed before the recorder's stop has been tried: wait for the `complete`, not for the phase.
    for _ in 0..<400 where await harness.uploader.completed.isEmpty {
      await harness.clock.advance(by: 11)  // the grace period the stream gets to deliver a tail first
      await harness.outbox.settled()
      try await Task.sleep(for: .milliseconds(5))
    }

    #expect(
      await harness.uploader.completed == [.init(memoID: id, segmentCount: 1)],
      "sent now, not at a stop that may never come")

    // The user's own stop afterwards finds the memo finished and reports it.
    let result = try #require(try await session.stop())
    #expect(result.memoID == id && result.segmentCount == 1 && result.failure == "engine restart failed")
    #expect(await harness.uploader.completed.count == 1)
    await session.shutdown()
    await harness.outbox.shutdown()
  }

  @Test func aFailedTakeWhoseStopThrowsAndHasNoSegmentLeavesNothingQueuedForTheServer() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = try await OutboxHarness()
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let recorder = StopThrowsRecorder(base: fake.recorder)
    let session = CaptureSession(
      session: fake.session, routes: fake.routes, recorder: recorder, outbox: harness.outbox, clock: harness.clock)
    let id = try await session.start(request)
    await recorder.fail(reason: "engine restart failed")
    try await waitForFailed(session)
    for _ in 0..<400 where await !session.isWaitingOutSilentRecorder(id) { try await Task.sleep(for: .milliseconds(5)) }

    await #expect(throws: CaptureError.recordingFailed("engine restart failed")) { try await session.stop() }
    await harness.outbox.settled()
    #expect(await harness.uploader.completed.isEmpty)
    #expect(await harness.outbox.queue().isEmpty)
    await session.shutdown()
    await harness.outbox.shutdown()
  }
}
