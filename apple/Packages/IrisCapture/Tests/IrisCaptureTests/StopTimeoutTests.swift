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

  /// Moves time on until the memo has been finished (its `complete` went out), i.e. the grace period after the timeout ran out.
  private func letTheGracePass(_ harness: OutboxHarness) async throws {
    for _ in 0..<400 where await harness.uploader.completed.isEmpty {
      await harness.clock.advance(by: 11)
      await harness.outbox.settled()
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
    try await letTheGracePass(harness)
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

  @Test func theTailSegmentAndTheStoppedEventThatComeAfterTheTimeoutAreUploaded() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (session, recorder, fake, harness) = try await rig(directory)
    await harness.uploader.hold()  // the memo stays unfinished on the server until the test lets it go
    try await session.start(request)
    await fake.recorder.feed(frames: 12 * SegmentRotationPolicy().sampleRate)  // segment 0 closed, 2 s still open
    let stopping = Task { try await session.stop() }
    try await letTheTimeoutPass(harness, on: session)
    let result = try await stopping.value
    #expect(result?.segmentCount == 1)
    #expect(await harness.uploader.completed.isEmpty, "the memo is not finished yet: its tail may still come")

    try await recorder.finishLate()  // the recorder flushes the open 2 s as segment 1, then reports `stopped`
    for _ in 0..<400 where await harness.outbox.entries().count < 2 { try await Task.sleep(for: .milliseconds(5)) }

    #expect(await session.current == .idle)
    #expect(await harness.outbox.entries().map(\.segment.index).sorted() == [0, 1], "the tail is queued with its take")
    await harness.uploader.releaseAll()
    try await letTheGracePass(harness)
    await harness.outbox.settled()
    #expect(await harness.uploader.completed.map(\.segmentCount) == [2], "finished once, with the tail")
    #expect(
      await harness.uploader.uploaded.map(\.index).sorted() == [0, 1], "and the tail went up, not into quarantine")
    await session.shutdown()
    await harness.outbox.shutdown()
  }

  @Test func aSegmentThatClosesAfterTheGracePeriodJoinsNothing() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (session, recorder, fake, harness) = try await rig(directory)
    let id = try await session.start(request)
    await fake.recorder.feed(frames: 12 * SegmentRotationPolicy().sampleRate)
    let stopping = Task { try await session.stop() }
    try await letTheTimeoutPass(harness, on: session)
    _ = try await stopping.value
    try await letTheGracePass(harness)  // the memo is finished with the one segment that closed

    try await recorder.finishLate()  // far too late
    let lateFile = directory.appending(path: "\(id.uuidString)-1.m4a")
    for _ in 0..<200 where !FileManager.default.fileExists(atPath: lateFile.path) {
      try await Task.sleep(for: .milliseconds(5))
    }
    try await Task.sleep(for: .milliseconds(50))  // the pump has handled both events

    await harness.outbox.settled()
    #expect(await harness.uploader.uploaded.map(\.index) == [0], "the late segment is not queued for a finished memo")
    #expect(FileManager.default.fileExists(atPath: lateFile.path), "and its audio is kept for the next launch's sweep")
    #expect(await harness.uploader.completed.map(\.segmentCount) == [1])
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

/// A recorder whose `stop()` hangs until the test lets it, optionally after it has already flushed and reported `stopped`.
private struct HungStopRecorder: SegmentRecorder {
  let base: FakeSegmentRecorder
  let release: AsyncStream<Void>
  /// Emit `stopped` (and flush the tail) first, then hang: the engine reported the end of the take but never returned.
  var reportsBeforeHanging = false

  var events: AsyncStream<CaptureEvent> { base.events }
  var levels: AsyncStream<Float> { base.levels }

  func start(memoID: MemoID) async throws { try await base.start(memoID: memoID) }
  func stop() async throws {
    if reportsBeforeHanging { try await base.stop() }
    for await _ in release {}
    if !reportsBeforeHanging { try await base.stop() }
  }
  func rotate(for reason: RotationReason) async { await base.rotate(for: reason) }
  func pause() async { await base.pause() }
  func resume() async { await base.resume() }
}

/// A recorder that does not even return from `stop()` must not hold the gate, and must not get a second take while its
/// microphone may still be open.
struct HungStopTests {
  private let request = TakeRequest(mode: "auto", title: "Voice memo")

  private func rig(
    _ directory: URL, reportsBeforeHanging: Bool
  ) async throws -> (CaptureSession, FakeCapture, OutboxHarness, AsyncStream<Void>.Continuation) {
    let harness = try await OutboxHarness()
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let (release, releaseSignal) = AsyncStream.makeStream(of: Void.self)
    let recorder = HungStopRecorder(base: fake.recorder, release: release, reportsBeforeHanging: reportsBeforeHanging)
    let session = CaptureSession(
      session: fake.session, routes: fake.routes, recorder: recorder, outbox: harness.outbox, clock: harness.clock,
      stopTimeout: 10)
    return (session, fake, harness, releaseSignal)
  }

  private func letTheTimeoutPass(_ harness: OutboxHarness, on session: CaptureSession) async throws {
    for _ in 0..<400 where await session.current.phase != .stopping { try await Task.sleep(for: .milliseconds(5)) }
    for _ in 0..<400 where await session.current.phase == .stopping {
      await harness.clock.advance(by: 11)
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  @Test func aRecorderWhoseStopNeverReturnsDoesNotBlockTheGateButRefusesTheNextTakeUntilItDoes() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (session, fake, harness, releaseSignal) = try await rig(directory, reportsBeforeHanging: false)
    try await session.start(request)
    await fake.recorder.feed(frames: 12 * SegmentRotationPolicy().sampleRate)

    let stopping = Task { try await session.stop() }
    try await letTheTimeoutPass(harness, on: session)
    let result = try await stopping.value
    #expect(result?.failure == "the recorder did not stop", "the stop is reported, not swallowed")
    #expect(await session.current == .idle, "the gate is free")

    await #expect(throws: CaptureError.engineFailure("the recorder is still stopping")) {
      try await session.start(request)
    }
    #expect(await session.cancel() == nil, "and nothing waits behind the hung stop")

    releaseSignal.finish()  // the engine finally lets go
    var started = false
    for _ in 0..<400 where !started {
      started = (try? await session.start(request)) != nil
      if !started { try await Task.sleep(for: .milliseconds(5)) }
    }
    #expect(started, "the next take starts once the stop has returned")
    await session.shutdown()
    await harness.outbox.shutdown()
  }

  @Test func aStoppedEventWhileStopHangsFinishesTheMemoOnceAndIsNotReportedAsSilent() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (session, fake, harness, releaseSignal) = try await rig(directory, reportsBeforeHanging: true)
    let id = try await session.start(request)
    await fake.recorder.feed(frames: 12 * SegmentRotationPolicy().sampleRate)  // segment 0 closed, 2 s open

    let stopping = Task { try await session.stop() }
    for _ in 0..<400 where await harness.uploader.completed.isEmpty {
      await harness.outbox.settled()
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await harness.uploader.completed.count == 1, "the pump finished the memo from the recorder's `stopped`")
    try await letTheTimeoutPass(harness, on: session)
    let result = try await stopping.value

    #expect(result?.segmentCount == 2 && result?.failure == nil, "the recorder did say it stopped")
    for _ in 0..<5 { await harness.clock.advance(by: 11) }  // a grace timer, if one were wrongly armed, fires here
    await harness.outbox.settled()
    #expect(
      await harness.uploader.completed == [.init(memoID: id, segmentCount: 2)], "finished once, with the whole take")
    releaseSignal.finish()
    await session.shutdown()
    await harness.outbox.shutdown()
  }
}
