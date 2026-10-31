import Foundation
import Testing

@testable import IrisCapture

/// A recorder whose `stop()` waits until the test lets it go.
private final class StopGate: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }

  func wait() async { for await _ in stream { return } }
  func open() { continuation.yield() }
}

private struct GatedStopRecorder: SegmentRecorder {
  let base: FakeSegmentRecorder
  let gate: StopGate

  var events: AsyncStream<CaptureEvent> { base.events }
  var levels: AsyncStream<Float> { base.levels }

  func start(memoID: MemoID) async throws { try await base.start(memoID: memoID) }
  func stop() async throws {
    await gate.wait()
    try await base.stop()
  }
  func rotate(for reason: RotationReason) async { await base.rotate(for: reason) }
  func pause() async { await base.pause() }
  func resume() async { await base.resume() }
}

/// A take that fails on its own lets go of the microphone before anyone stops it.
struct FailedTakeReleasedTests {
  private let request = TakeRequest(mode: "auto", title: "Voice memo")

  // MARK: A take that fails on its own

  private func waitFor(_ session: CaptureSession, _ condition: (TakeState) -> Bool) async throws -> Bool {
    for _ in 0..<400 {
      if condition(await session.current) { return true }
      try await Task.sleep(for: .milliseconds(5))
    }
    return condition(await session.current)
  }

  @Test func aTakeThatFailsOnItsOwnReportsItsMicrophoneReleasedOnceTheRecorderHasStopped() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = try await OutboxHarness()
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let gate = StopGate()
    let session = CaptureSession(
      session: fake.session, routes: fake.routes, recorder: GatedStopRecorder(base: fake.recorder, gate: gate),
      outbox: harness.outbox, clock: harness.clock)
    _ = try await session.start(request)
    await fake.recorder.feed(frames: 12 * SegmentRotationPolicy().sampleRate)

    await fake.recorder.fail(reason: "engine restart failed")
    #expect(try await waitFor(session) { $0.phase == .failed })
    #expect(
      await session.current.recorderReleased == false,
      "the recorder's stop has not returned: the microphone may be open")

    gate.open()
    #expect(try await waitFor(session) { $0.recorderReleased }, "no Stop or Discard needed: the take says it let go")
    #expect(await session.current.phase == .failed, "it still waits for the user, with what it captured")
    await session.shutdown()
    await harness.outbox.shutdown()
  }

  @Test func aTakeThatIsRecordingIsNeverReportedReleased() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let harness = try await OutboxHarness()
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let session = CaptureSession(
      session: fake.session, routes: fake.routes, recorder: fake.recorder, outbox: harness.outbox, clock: harness.clock)
    _ = try await session.start(request)

    #expect(await session.current.recorderReleased == false)
    await session.shutdown()
    await harness.outbox.shutdown()
  }
}
