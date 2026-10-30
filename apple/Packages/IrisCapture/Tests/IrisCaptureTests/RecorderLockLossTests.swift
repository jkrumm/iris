import Foundation
import Testing

@testable import IrisCapture

/// A take that meets a lock-time interruption, a session that will not reactivate, or a media-services reset: nothing that was
/// captured is lost, and a recorder that stops ends the take early with everything it has already on its way to the server.
struct RecorderLockLossTests {
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
      clock: harness.clock, reactivationDelay: 0)
    return Rig(session: session, fake: fake, harness: harness, directory: directory)
  }

  private func finish(_ rig: Rig) async {
    await rig.session.shutdown()
    await rig.harness.outbox.shutdown()
    try? FileManager.default.removeItem(at: rig.directory)
  }

  private let request = TakeRequest(mode: "auto", title: "Voice memo")

  private func wait(_ phase: TakePhase, in session: CaptureSession) async throws {
    for _ in 0..<300 {
      if await session.current.phase == phase { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("the take never reached \(phase)")
  }

  private func waitForCompletion(of id: MemoID, in rig: Rig) async throws -> TestUploader.CompleteCall? {
    for _ in 0..<300 {
      await rig.harness.outbox.settled()
      if let call = await rig.harness.uploader.completed.first(where: { $0.memoID == id }) { return call }
      try await Task.sleep(for: .milliseconds(10))
    }
    return nil
  }

  /// The system interrupts the session: the recorder pauses (the fake session delivers it; the recorder is driven by the take).
  private func interrupt(_ rig: Rig) async throws {
    await rig.fake.session.deliver(.began)
    try await wait(.paused, in: rig.session)
  }

  @Test func aResumeThatFailsKeepsTheSegmentsAndSendsThemWithoutAStop() async throws {
    let rig = try await makeRig()
    let id = try await rig.session.start(request)
    await rig.fake.record(seconds: 14)  // one closed segment, 4 s open
    try await interrupt(rig)  // the pause closes the 4 s partial
    await rig.fake.recorder.failNextResume(reason: "engine resume failed")
    await rig.fake.session.deliver(.ended(shouldResume: true))
    try await wait(.failed, in: rig.session)

    let state = await rig.session.current
    #expect(state.failure == "engine resume failed", "the user sees that the take ended early")
    let call = try #require(try await waitForCompletion(of: id, in: rig), "the memo is sent with nobody tapping stop")
    #expect(call.segmentCount == 2)
    #expect(await rig.harness.uploader.uploaded.count == 2)

    let result = try #require(try await rig.session.stop())
    #expect(result.segmentCount == 2)
    #expect(result.failure == "engine resume failed")
    #expect(await rig.harness.uploader.completed.count == 1, "stopping the failed take does not send the memo twice")
    await finish(rig)
  }

  @Test func aRecorderThatFailsMidSegmentClosesAndSendsTheOpenSegment() async throws {
    let rig = try await makeRig()
    let id = try await rig.session.start(request)
    await rig.fake.record(seconds: 12)  // segment 0 closed, 2 s open
    await rig.fake.recorder.fail(reason: "engine restart failed")
    try await wait(.failed, in: rig.session)

    let call = try #require(try await waitForCompletion(of: id, in: rig))
    #expect(call.segmentCount == 2, "the 2 s in the open segment are closed, queued and sent")
    await finish(rig)
  }

  @Test func anInterruptionThatEndsWithShouldResumeReactivatesTheSessionAndContinuesInANewSegment() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    await rig.fake.record(seconds: 3)
    try await interrupt(rig)
    let before = await rig.fake.session.activationCount
    await rig.fake.session.deliver(.ended(shouldResume: true))
    try await wait(.recording, in: rig.session)

    #expect(await rig.fake.session.activationCount == before + 1, "an interruption can leave the session inactive")
    await rig.fake.record(seconds: 4)
    let result = try await rig.session.stop()
    await rig.harness.outbox.settled()
    #expect(result?.segmentCount == 2)
    #expect(result?.failure == nil)
    await finish(rig)
  }

  @Test func anInterruptionThatEndsWithoutShouldResumeLeavesTheTakePausedAndLosesNothing() async throws {
    let rig = try await makeRig()
    let id = try await rig.session.start(request)
    await rig.fake.record(seconds: 3)
    try await interrupt(rig)
    let before = await rig.fake.session.activationCount
    await rig.fake.session.deliver(.ended(shouldResume: false))
    try await Task.sleep(for: .milliseconds(50))

    #expect(await rig.session.current.phase == .paused, "the take is visibly paused, not silently recording nothing")
    #expect(await rig.fake.session.activationCount == before)
    let result = try #require(try await rig.session.stop())
    #expect(result.memoID == id)
    #expect(result.segmentCount == 1, "the 3 s captured before the interruption are kept")
    await finish(rig)
  }

  @Test func aSessionThatReactivatesOnTheSecondTryResumesTheTake() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    await rig.fake.record(seconds: 2)
    try await interrupt(rig)
    await rig.fake.session.failActivations(1)
    await rig.fake.session.deliver(.ended(shouldResume: true))
    try await wait(.recording, in: rig.session)
    await rig.session.cancel()
    await finish(rig)
  }

  @Test func aSessionThatNeverReactivatesFailsTheTakeAndSendsWhatItHas() async throws {
    let rig = try await makeRig()
    let id = try await rig.session.start(request)
    await rig.fake.record(seconds: 5)
    try await interrupt(rig)
    await rig.fake.session.failActivations(100)
    await rig.fake.session.deliver(.ended(shouldResume: true))
    try await wait(.failed, in: rig.session)

    #expect(await rig.session.current.failure == "audio session could not be restored")
    let call = try #require(try await waitForCompletion(of: id, in: rig))
    #expect(call.segmentCount == 1)
    await finish(rig)
  }

  @Test func aMediaServicesResetClosesTheSegmentRebuildsTheSessionAndContinues() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    await rig.fake.record(seconds: 3)
    let configured = await rig.fake.session.configureCount
    let activated = await rig.fake.session.activationCount
    await rig.fake.mediaServicesReset()
    for _ in 0..<300 where await rig.fake.session.configureCount == configured {
      try await Task.sleep(for: .milliseconds(10))
    }
    try await wait(.recording, in: rig.session)

    #expect(await rig.fake.session.configureCount == configured + 1, "the category is set again")
    #expect(await rig.fake.session.activationCount == activated + 1)
    await rig.fake.record(seconds: 4)
    let result = try await rig.session.stop()
    await rig.harness.outbox.settled()
    #expect(result?.segmentCount == 2, "3 s before the reset, 4 s after, in separate files")
    #expect(result?.failure == nil)
    await finish(rig)
  }

  @Test func aMediaServicesResetWithNoTakeDoesNothing() async throws {
    let rig = try await makeRig()
    await rig.fake.mediaServicesReset()
    try await Task.sleep(for: .milliseconds(50))
    #expect(await rig.session.current == .idle)
    await finish(rig)
  }

  // MARK: Route changes and mic switches

  @Test func aMicSwitchToTheHeadsetAndBackKeepsRecordingInASegmentPerInput() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    await rig.fake.record(seconds: 3)
    try await rig.session.switchInput(to: FakeRouteManager.headsetMic.uid)
    await rig.fake.engineConfigurationChanged()  // the engine stops itself when the input changes
    await rig.fake.record(seconds: 3)
    try await rig.session.switchInput(to: FakeRouteManager.builtInMic.uid)
    await rig.fake.engineConfigurationChanged()
    await rig.fake.record(seconds: 3)
    let result = try #require(try await rig.session.stop())
    await rig.harness.outbox.settled()

    #expect(result.segmentCount == 3)
    #expect(result.failure == nil)
    #expect(await rig.session.current == .idle)
    #expect(await rig.harness.uploader.completed.map(\.segmentCount) == [3])
    await finish(rig)
  }

  @Test func anEngineThatCannotRestartOnTheNewInputClosesAndSendsEverythingCaptured() async throws {
    let rig = try await makeRig()
    let id = try await rig.session.start(request)
    await rig.fake.record(seconds: 4)
    try await rig.session.switchInput(to: FakeRouteManager.headsetMic.uid)
    await rig.fake.record(seconds: 5)  // open when the restart fails
    await rig.fake.engineConfigurationChanged()
    await rig.fake.recorder.fail(reason: "engine restart failed")
    try await wait(.failed, in: rig.session)

    let call = try #require(try await waitForCompletion(of: id, in: rig))
    #expect(call.segmentCount == 2, "4 s on the built-in mic, 5 s on the headset")
    #expect(await rig.session.current.failure == "engine restart failed")
    await finish(rig)
  }
}
