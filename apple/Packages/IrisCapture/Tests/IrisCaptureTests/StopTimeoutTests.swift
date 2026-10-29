import Foundation
import Testing

@testable import IrisCapture

/// A recorder whose `stop()` returns but which never emits `.stopped`: it went silent.
private struct SilentStopRecorder: SegmentRecorder {
  let base: FakeSegmentRecorder

  var events: AsyncStream<CaptureEvent> { base.events }
  var levels: AsyncStream<Float> { base.levels }

  func start(memoID: MemoID) async throws { try await base.start(memoID: memoID) }
  func stop() async throws {}
  func rotate(for reason: RotationReason) async { await base.rotate(for: reason) }
  func pause() async { await base.pause() }
  func resume() async { await base.resume() }

  /// Lets the stop that was given up on finish late.
  func finishLate() async throws { try await base.stop() }
}

/// `stop()` and `cancel()` hold the session's gate while they wait for the recorder's last event; a recorder that never
/// sends it must not hold the gate for ever.
struct StopTimeoutTests {
  private let request = TakeRequest(mode: "auto", title: "Voice memo")

  private func rig(_ directory: URL) async throws -> (CaptureSession, SilentStopRecorder, FakeCapture, OutboxHarness) {
    let harness = try await OutboxHarness()
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let recorder = SilentStopRecorder(base: fake.recorder)
    let session = CaptureSession(
      session: fake.session, routes: fake.routes, recorder: recorder, outbox: harness.outbox, clock: harness.clock,
      stopTimeout: 10)
    return (session, recorder, fake, harness)
  }

  /// Waits for the stop (or cancel) to reach its wait, then moves time past the timeout until it gives up. The clock is
  /// advanced repeatedly rather than once after a pause: the advance that lands after the timer is parked is the one that fires it.
  private func letTheTimeoutPass(_ harness: OutboxHarness, on session: CaptureSession) async throws {
    for _ in 0..<400 where await session.current.phase != .stopping { try await Task.sleep(for: .milliseconds(5)) }
    for _ in 0..<400 where await session.current.phase == .stopping {
      await harness.clock.advance(by: 11)
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  @Test func aStopWhoseRecorderNeverReportsEndsWithWhatClosedAndSaysWhy() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (session, _, fake, harness) = try await rig(directory)
    let id = try await session.start(request)
    await fake.recorder.feed(frames: 12 * SegmentRotationPolicy().sampleRate)  // one segment closed, a partial open

    let stopping = Task { try await session.stop() }
    try await letTheTimeoutPass(harness, on: session)
    let result = try await stopping.value

    #expect(result?.memoID == id)
    #expect(result?.segmentCount == 1, "the segment that closed is the take")
    #expect(result?.failure == "the recorder did not stop", "a clear failure, not silence")
    #expect(await session.current == .idle, "the gate is free and the session usable")
    await harness.outbox.settled()
    #expect(await harness.uploader.completed == [.init(memoID: id, segmentCount: 1)], "finished with what it has")
    await session.shutdown()
    await harness.outbox.shutdown()
  }

  @Test func aSilentRecorderThatClosedNothingThrowsRecordingFailed() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (session, _, _, harness) = try await rig(directory)
    try await session.start(request)

    let stopping = Task { try await session.stop() }
    try await letTheTimeoutPass(harness, on: session)

    await #expect(throws: CaptureError.recordingFailed("the recorder did not stop")) { try await stopping.value }
    #expect(await session.current == .idle)
    #expect(await harness.outbox.items().isEmpty, "nothing of the take stays queued")
    await session.shutdown()
    await harness.outbox.shutdown()
  }

  @Test func theGateIsFreeAfterTheTimeout() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (session, _, fake, harness) = try await rig(directory)
    try await session.start(request)
    await fake.recorder.feed(frames: 12 * SegmentRotationPolicy().sampleRate)
    let stopping = Task { try await session.stop() }
    try await letTheTimeoutPass(harness, on: session)
    _ = try await stopping.value

    // Another call goes straight through the gate instead of waiting behind the stop.
    #expect(await session.cancel() == nil)
    await session.shutdown()
    await harness.outbox.shutdown()
  }

  @Test func aSegmentAndAStoppedEventThatComeAfterTheTimeoutJoinNothing() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (session, recorder, fake, harness) = try await rig(directory)
    await harness.uploader.hold()  // the memo stays unfinished on the server, so a stray segment could still join it
    let id = try await session.start(request)
    await fake.recorder.feed(frames: 12 * SegmentRotationPolicy().sampleRate)  // segment 0 closed, 2 s still open
    let stopping = Task { try await session.stop() }
    try await letTheTimeoutPass(harness, on: session)
    let result = try await stopping.value
    #expect(result?.segmentCount == 1)

    try await recorder.finishLate()  // the recorder flushes the open 2 s as segment 1, then reports `stopped`
    let lateFile = directory.appending(path: "\(id.uuidString)-1.m4a")
    for _ in 0..<200 where !FileManager.default.fileExists(atPath: lateFile.path) {
      try await Task.sleep(for: .milliseconds(5))
    }
    try await Task.sleep(for: .milliseconds(50))  // the pump has handled both events

    #expect(await session.current == .idle)
    #expect(
      await harness.outbox.entries().map(\.segment.index) == [0], "the late segment is not queued for a finished memo")
    #expect(FileManager.default.fileExists(atPath: lateFile.path), "and its audio is kept for the next launch's sweep")
    await harness.uploader.releaseAll()
    await harness.outbox.settled()
    #expect(await harness.uploader.completed.map(\.segmentCount) == [1], "finished once, with what the stop had")
    #expect(await harness.uploader.uploaded.map(\.index) == [0])
    await session.shutdown()
    await harness.outbox.shutdown()
  }

  @Test func aCancelWhoseRecorderNeverReportsStillReturns() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (session, _, _, harness) = try await rig(directory)
    let id = try await session.start(request)

    let cancelling = Task { await session.cancel() }
    try await letTheTimeoutPass(harness, on: session)

    #expect(await cancelling.value == id)
    #expect(await session.current == .idle)
    await session.shutdown()
    await harness.outbox.shutdown()
  }
}
