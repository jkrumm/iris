import Foundation
import Testing

@testable import IrisCapture

/// A recorder whose `stop()` first puts its tail on the stream (when asked), then waits for the test and throws or returns.
private struct ScriptedStopRecorder: SegmentRecorder {
  struct StopFailed: Error {}

  enum Ending { case throwsAtOnce, waitsForRelease }

  let base: FakeSegmentRecorder
  let release: AsyncStream<Void>
  var ending = Ending.waitsForRelease
  /// `stop()` flushes the open segment and reports `stopped` (the base recorder's stop) before it fails.
  var flushesFirst = false

  var events: AsyncStream<CaptureEvent> { base.events }
  var levels: AsyncStream<Float> { base.levels }

  func start(memoID: MemoID) async throws { try await base.start(memoID: memoID) }

  func stop() async throws {
    if flushesFirst { try await base.stop() }
    if ending == .waitsForRelease { for await _ in release {} }
    if ending == .throwsAtOnce || flushesFirst { throw StopFailed() }
    try await base.stop()
  }

  func rotate(for reason: RotationReason) async { await base.rotate(for: reason) }
  func pause() async { await base.pause() }
  func resume() async { await base.resume() }
  func fail(reason: String) async { await base.fail(reason: reason) }
}

struct StopTrackingTests {
  private let request = TakeRequest(mode: "auto", title: "Voice memo")

  private struct Rig {
    let session: CaptureSession
    let fake: FakeCapture
    let harness: OutboxHarness
    let release: AsyncStream<Void>.Continuation
    let recorder: ScriptedStopRecorder
  }

  private func rig(
    _ directory: URL, ending: ScriptedStopRecorder.Ending, flushesFirst: Bool = false,
    session makeSession: ((FakeAudioSessionController) -> any AudioSessionController)? = nil
  ) async throws -> Rig {
    let harness = try await OutboxHarness()
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let (stream, release) = AsyncStream.makeStream(of: Void.self)
    let recorder = ScriptedStopRecorder(
      base: fake.recorder, release: stream, ending: ending, flushesFirst: flushesFirst)
    let session = CaptureSession(
      session: makeSession?(fake.session) ?? fake.session, routes: fake.routes, recorder: recorder,
      outbox: harness.outbox, clock: harness.clock, stopTimeout: 10)
    return Rig(session: session, fake: fake, harness: harness, release: release, recorder: recorder)
  }

  private func waitForPhase(_ phase: TakePhase, _ session: CaptureSession) async throws {
    for _ in 0..<400 where await session.current.phase != phase { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await session.current.phase == phase)
  }

  /// Moves time on (the stop's timeout, then the grace period) until a `complete` goes out.
  private func letTheTimeoutsPass(_ rig: Rig) async throws {
    for _ in 0..<400 where await rig.harness.uploader.completed.isEmpty {
      await rig.harness.clock.advance(by: 11)
      await rig.harness.outbox.settled()
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  // MARK: The audio session under a stop that has not returned

  @Test func cancellingAFailedTakeWhileItsStopIsStillRunningLeavesTheSessionActive() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let rig = try await rig(directory, ending: .waitsForRelease)
    try await rig.session.start(request)
    await rig.fake.record(seconds: 12)
    await rig.recorder.fail(reason: "engine restart failed")
    // `failTake` is inside `recorder.stop()`, which has not been given up on
    try await waitForPhase(.failed, rig.session)

    #expect(await rig.session.cancel() != nil)

    #expect(
      await rig.fake.session.isActive, "the recorder's stop is still running: the session is not pulled from under it")
    await #expect(throws: CaptureError.engineFailure("the recorder is still stopping")) {
      try await rig.session.start(request)
    }

    rig.release.finish()  // the stop returns
    for _ in 0..<400 where await rig.fake.session.isActive { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await !rig.fake.session.isActive, "and the session goes with it")
    await rig.session.shutdown()
    await rig.harness.outbox.shutdown()
  }
}
