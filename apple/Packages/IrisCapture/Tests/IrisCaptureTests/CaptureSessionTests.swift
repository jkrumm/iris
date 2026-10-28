import Foundation
import Testing

@testable import IrisCapture

struct CaptureSessionTests {
  private struct Rig {
    let session: CaptureSession
    let fake: FakeCapture
    let harness: OutboxHarness
    let directory: URL
  }

  private func makeRig() async throws -> Rig {
    let directory = try temporaryDirectory()
    let harness = try await OutboxHarness()
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let session = CaptureSession(
      session: fake.session, routes: fake.routes, recorder: fake.recorder, outbox: harness.outbox,
      clock: harness.clock)
    return Rig(session: session, fake: fake, harness: harness, directory: directory)
  }

  private func finish(_ rig: Rig) async {
    await rig.session.shutdown()
    await rig.harness.outbox.shutdown()
    try? FileManager.default.removeItem(at: rig.directory)
  }

  private let request = TakeRequest(mode: "hermes", threadID: "thread-1", title: "Voice reply")

  @Test func aTakeCreatesTheMemoFirstThenUploadsItsSegmentsAndCompletes() async throws {
    let rig = try await makeRig()
    let id = try await rig.session.start(request)
    #expect(await rig.session.current.phase == .recording)
    await rig.fake.record(seconds: 12)
    let result = try #require(try await rig.session.stop())
    await rig.harness.outbox.settled()

    #expect(result.memoID == id)
    #expect(result.segmentCount == 2)
    let created = try #require(await rig.harness.uploader.created.first)
    #expect(created.memoID == id)
    #expect(created.kind == .voice)
    #expect(created.mode == "hermes")
    #expect(created.threadID == "thread-1")
    let log = await rig.harness.uploader.log
    #expect(log.first == "create")
    #expect(log.last == "complete")
    #expect(await rig.harness.uploader.completed == [.init(memoID: id, segmentCount: 2)])
    #expect(await rig.harness.outbox.queue().isEmpty)
    #expect(await rig.session.current == .idle)
    await finish(rig)
  }

  @Test func aFailedCreateWhileRecordingShowsInTheQueueAndIsRetriedAfterTheStop() async throws {
    let rig = try await makeRig()
    await rig.harness.uploader.failNextCreates(1)
    try await rig.session.start(request)
    // Frames straight into the recorder (the clock stays put): 10 s close the first segment, so the memo is created.
    await rig.fake.recorder.feed(frames: 10 * SegmentRotationPolicy().sampleRate)
    // The segment travels recorder -> event pump -> outbox: poll (bounded) until the create has failed.
    var create: OutboxState?
    for _ in 0..<200 {
      await rig.harness.outbox.settled()
      create = await rig.harness.outbox.items().first?.create
      if case .failed? = create { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    guard case .failed(let retryAt)? = create else {
      Issue.record("expected a failed create, got \(String(describing: create))")
      await finish(rig)
      return
    }
    #expect(retryAt > (await rig.harness.clock.now()))
    // The row stays a recording one while the take runs: Settings must not offer Retry or Discard on a live take.
    #expect(await rig.harness.outbox.queue().first?.status == .recording)

    await rig.fake.record(seconds: 1)
    try await rig.session.stop()
    if case .failed(let at?, _)? = await rig.harness.outbox.queue().first?.status {
      #expect(at > (await rig.harness.clock.now()), "after the stop the failure shows, with its retry time")
    } else {
      Issue.record("expected the failed create to show once the take is over")
    }
    await rig.harness.clock.advance(by: 30)
    // The retry timer is a task: poll (bounded) until the memo has gone through.
    for _ in 0..<200 {
      await rig.harness.outbox.settled()
      if await rig.harness.uploader.completed.count == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await rig.harness.uploader.completed.count == 1)
    #expect(await rig.harness.outbox.queue().isEmpty)
    await finish(rig)
  }

  @Test func aTakeCancelledBeforeItsFirstSegmentNeverReachesTheServer() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    await rig.fake.record(seconds: 4)
    await rig.session.cancel()
    await rig.harness.outbox.settled()

    #expect(await rig.harness.uploader.createAttempts == 0)
    #expect(await rig.harness.outbox.queue().isEmpty)
    await finish(rig)
  }

  @Test func aRecorderFailureBeforeAnySegmentMakesStopThrowInsteadOfDroppingTheTakeSilently() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    await rig.fake.recorder.fail(reason: "segment write failed")

    await #expect(throws: CaptureError.recordingFailed("segment write failed")) { try await rig.session.stop() }
    await rig.harness.outbox.settled()
    #expect(await rig.harness.outbox.queue().isEmpty)
    #expect(await rig.session.current == .idle)
    await finish(rig)
  }

  @Test func aRecorderFailureShowsInTheTakeStateAndKeepsWhatWasCaptured() async throws {
    let rig = try await makeRig()
    let id = try await rig.session.start(request)
    await rig.fake.record(seconds: 12)  // one closed segment, 2 s in the open one
    await rig.fake.recorder.fail(reason: "segment write failed")

    var state = await rig.session.current
    for _ in 0..<200 where state.phase != .failed {
      try await Task.sleep(for: .milliseconds(10))
      state = await rig.session.current
    }
    #expect(state.phase == .failed)
    #expect(state.failure == "segment write failed")

    let result = try #require(try await rig.session.stop())
    await rig.harness.outbox.settled()
    #expect(result.memoID == id)
    #expect(result.segmentCount >= 1)
    #expect(result.failure == "segment write failed")
    #expect(await rig.harness.uploader.completed.map(\.memoID) == [id])
    #expect(await rig.session.current == .idle)
    await finish(rig)
  }

  @Test func aFailedTakeCanBeCancelled() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    await rig.fake.record(seconds: 12)
    await rig.fake.recorder.fail(reason: "engine restart failed")
    var phase = await rig.session.current.phase
    for _ in 0..<200 where phase != .failed {
      try await Task.sleep(for: .milliseconds(10))
      phase = await rig.session.current.phase
    }
    #expect(phase == .failed)

    await rig.session.cancel()
    await rig.harness.outbox.settled()
    #expect(await rig.session.current == .idle)
    #expect(await rig.harness.outbox.queue().isEmpty)
    #expect(await rig.harness.uploader.completed.isEmpty)
    await finish(rig)
  }

  @Test func aSecondStartWhileRecordingIsRejected() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    await #expect(throws: CaptureError.alreadyRecording) { try await rig.session.start(request) }
    await rig.session.cancel()
    await finish(rig)
  }

  @Test func stopWithoutATakeThrows() async throws {
    let rig = try await makeRig()
    await #expect(throws: CaptureError.notRecording) { try await rig.session.stop() }
    await finish(rig)
  }

  @Test func aTakeThatNeverHeardAnythingIsDropped() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    let result = try await rig.session.stop()
    await rig.harness.outbox.settled()

    #expect(result == nil)
    #expect(await rig.harness.outbox.queue().isEmpty)
    await finish(rig)
  }

  @Test func cancelSendsNothingAndDeletesTheFiles() async throws {
    let rig = try await makeRig()
    await rig.harness.uploader.hold()
    try await rig.session.start(request)
    await rig.fake.record(seconds: 11)  // one closed segment
    await rig.session.cancel()
    await rig.harness.uploader.releaseAll()
    await rig.harness.outbox.settled()

    #expect(await rig.harness.outbox.queue().isEmpty)
    #expect(await rig.harness.uploader.completed.isEmpty)
    #expect(await rig.session.current == .idle)
    let files = try FileManager.default.contentsOfDirectory(atPath: rig.directory.path).filter { $0.hasSuffix(".m4a") }
    #expect(files.isEmpty)
    await finish(rig)
  }

  @Test func anInterruptionPausesTheTakeAndResumeContinuesIt() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    await rig.fake.record(seconds: 2)
    await rig.fake.interrupt()
    try await waitForPhase(.paused, in: rig.session)
    await rig.fake.record(seconds: 3)  // dropped while paused
    await rig.fake.endInterruption(shouldResume: true)
    try await waitForPhase(.recording, in: rig.session)
    await rig.fake.record(seconds: 4)
    let result = try await rig.session.stop()
    await rig.harness.outbox.settled()

    #expect(result?.segmentCount == 2, "the interruption closed segment 0 (2 s); the rest is segment 1 (4 s)")
    #expect(await rig.harness.uploader.uploaded.count == 2)
    await finish(rig)
  }

  @Test func anInterruptionThatDoesNotRecommendResumingKeepsTheTakePaused() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    await rig.fake.record(seconds: 2)
    await rig.fake.interrupt()
    try await waitForPhase(.paused, in: rig.session)
    await rig.fake.endInterruption(shouldResume: false)
    try await Task.sleep(for: .milliseconds(50))
    #expect(await rig.session.current.phase == .paused)

    await rig.session.resume()
    #expect(await rig.session.current.phase == .recording)
    await rig.session.cancel()
    await finish(rig)
  }

  @Test func switchingTheMicrophoneRollsTheSegmentAndUpdatesTheInputName() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    #expect(await rig.session.current.inputName == FakeRouteManager.builtInMic.name)
    await rig.fake.record(seconds: 2)
    try await rig.session.switchInput(to: FakeRouteManager.headsetMic.uid)
    #expect(await rig.session.current.inputName == FakeRouteManager.headsetMic.name)
    await rig.fake.record(seconds: 2)
    let result = try await rig.session.stop()
    #expect(result?.segmentCount == 2)
    await finish(rig)
  }

  @Test func aRouteRuleSelectsTheInputAtStart() async throws {
    let rig = try await makeRig()
    let route = await rig.fake.routes.currentRoute()
    await rig.fake.routes.setRule(fingerprint: route.fingerprint, preferredPortUID: FakeRouteManager.headsetMic.uid)
    try await rig.session.start(request)
    #expect(await rig.session.current.inputName == FakeRouteManager.headsetMic.name)
    await rig.session.cancel()
    await finish(rig)
  }

  @Test func aRouteRuleThatAppliesMidTakeRollsTheSegmentSoOneFileHasOneInput() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    await rig.fake.record(seconds: 3)
    let route = await rig.fake.routes.currentRoute()
    await rig.fake.routes.setRule(fingerprint: route.fingerprint, preferredPortUID: FakeRouteManager.headsetMic.uid)
    await rig.fake.routes.setAvailable(
      inputs: route.availableInputs, outputUIDs: route.outputUIDs, reason: .deviceAppeared)

    var entries = 0
    for _ in 0..<200 where entries == 0 {
      try await Task.sleep(for: .milliseconds(10))
      entries = await rig.harness.outbox.entries().count
    }
    #expect(entries == 1, "the 3 s on the built-in mic closed as their own segment when the input changed")
    #expect(await rig.fake.routes.currentRoute().currentInput == FakeRouteManager.headsetMic)
    #expect(await rig.session.current.inputName == FakeRouteManager.headsetMic.name)
    await rig.session.cancel()
    await finish(rig)
  }

  @Test func aRouteChangeAfterTheTakeHasEndedDoesNotTouchTheInput() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    await rig.fake.record(seconds: 2)
    _ = try await rig.session.stop()
    let route = await rig.fake.routes.currentRoute()
    await rig.fake.routes.setRule(fingerprint: route.fingerprint, preferredPortUID: FakeRouteManager.headsetMic.uid)
    await rig.fake.routes.setAvailable(
      inputs: route.availableInputs, outputUIDs: route.outputUIDs, reason: .deviceAppeared)

    try await Task.sleep(for: .milliseconds(200))
    #expect(await rig.fake.routes.currentRoute().currentInput == FakeRouteManager.builtInMic)
    await finish(rig)
  }

  @Test func updatesStartWithTheCurrentStateAndFollowThePhases() async throws {
    let rig = try await makeRig()
    var iterator = await rig.session.updates().makeAsyncIterator()
    #expect(await iterator.next() == .idle)
    try await rig.session.start(request)
    var last: TakeState?
    while let state = await iterator.next() {
      last = state
      if state.phase == .recording, state.inputName != nil { break }
    }
    #expect(last?.phase == .recording)
    #expect(last?.request == request)
    await rig.session.cancel()
    await finish(rig)
  }

  /// Bounded poll: an interruption event travels through a stream, so the phase changes a moment later.
  private func waitForPhase(_ phase: TakePhase, in session: CaptureSession) async throws {
    for _ in 0..<200 {
      if await session.current.phase == phase { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("the take never reached \(phase)")
  }
}
