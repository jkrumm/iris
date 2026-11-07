import Foundation
import Testing

@testable import IrisCapture

/// A resume the system refuses while the app is in the background (`!int`) does not end the take: it waits, paused and whole, for
/// the app to come back, and is finished with what it has when the app does not come back in time.
struct BackgroundResumeTests {
  private struct Rig {
    let session: CaptureSession
    let fake: FakeCapture
    let harness: OutboxHarness
    let events: RecordingCaptureEvents
    let directory: URL
  }

  private func makeRig(limit: TimeInterval = 600) async throws -> Rig {
    let directory = try temporaryDirectory()
    let harness = try await OutboxHarness()
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let events = RecordingCaptureEvents()
    let session = CaptureSession(
      session: fake.session, routes: fake.routes, recorder: fake.recorder, outbox: harness.outbox,
      clock: harness.clock, reactivationDelay: 0, events: events, appActivity: fake.appActivity,
      backgroundResumeLimit: limit)
    return Rig(session: session, fake: fake, harness: harness, events: events, directory: directory)
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

  private func waitForEvent(_ type: String, in rig: Rig) async throws {
    for _ in 0..<300 {
      if rig.events.entries(named: "audio.interruption").contains(where: { $0.attributes["type"] == .string(type) }) {
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("no \(type) event")
  }

  private func waitForCompletion(of id: MemoID, in rig: Rig) async throws -> TestUploader.CompleteCall? {
    for _ in 0..<300 {
      await rig.harness.outbox.settled()
      if let call = await rig.harness.uploader.completed.first(where: { $0.memoID == id }) { return call }
      try await Task.sleep(for: .milliseconds(10))
    }
    return nil
  }

  /// A take with 5 s recorded, interrupted while the app is in the background, whose activation is refused.
  private func refusedInBackground(_ rig: Rig) async throws -> MemoID {
    let id = try await rig.session.start(request)
    await rig.fake.record(seconds: 5)
    await rig.fake.appActivity.setActive(false)
    await rig.fake.session.deliver(.began)
    try await wait(.paused, in: rig.session)
    await rig.fake.session.failActivations(100, refused: true)
    await rig.fake.session.deliver(.ended(shouldResume: true))
    try await waitForEvent("resume_deferred", in: rig)
    return id
  }

  @Test func aRefusedResumeInTheBackgroundKeepsTheTakePausedAndSaysSo() async throws {
    let rig = try await makeRig()
    let id = try await refusedInBackground(rig)
    try await Task.sleep(for: .milliseconds(50))

    let state = await rig.session.current
    #expect(state.phase == .paused)
    #expect(state.failure == nil)
    #expect(await rig.harness.uploader.completed.isEmpty, "the memo is not finished while it waits")
    let deferred = try #require(
      rig.events.entries(named: "audio.interruption").first { $0.attributes["type"] == "resume_deferred" })
    #expect(deferred.memoID == id)
    #expect(!deferred.error)
    #expect(deferred.attributes["app.active"] == false)
    await finish(rig)
  }

  @Test func theAppBecomingActiveResumesTheTakeInANewSegment() async throws {
    let rig = try await makeRig()
    let id = try await refusedInBackground(rig)
    await rig.fake.session.failActivations(0)
    await rig.fake.appActivity.setActive(true)
    try await wait(.recording, in: rig.session)

    #expect(await rig.fake.session.isActive)
    #expect(rig.events.entries(named: "capture.gap").count == 1, "the gap of the interruption is closed")
    await rig.fake.record(seconds: 4)
    let result = try #require(try await rig.session.stop())
    await rig.harness.outbox.settled()
    #expect(result.memoID == id)
    #expect(result.segmentCount == 2, "5 s before the interruption, 4 s after")
    #expect(result.failure == nil)
    await finish(rig)
  }

  @Test func theAppBecomingActiveOverAStillRefusedSessionFailsTheTake() async throws {
    let rig = try await makeRig()
    let id = try await refusedInBackground(rig)
    await rig.fake.appActivity.setActive(true)
    try await wait(.failed, in: rig.session)

    #expect(await rig.session.current.failure == "audio session could not be restored")
    let call = try #require(try await waitForCompletion(of: id, in: rig))
    #expect(call.segmentCount == 1)
    await finish(rig)
  }

  @Test func aStopWhileWaitingFinishesTheTakeAndNothingResumesAfterwards() async throws {
    let rig = try await makeRig()
    let id = try await refusedInBackground(rig)
    let result = try #require(try await rig.session.stop())
    await rig.harness.outbox.settled()
    #expect(result.memoID == id)
    #expect(result.segmentCount == 1, "what was captured before the interruption")

    let activations = await rig.fake.session.activationCount
    await rig.fake.session.failActivations(0)
    await rig.fake.appActivity.setActive(true)
    await rig.harness.clock.advance(by: 10_000)
    try await Task.sleep(for: .milliseconds(80))
    await rig.harness.outbox.settled()

    #expect(await rig.session.current.phase == .idle)
    #expect(await rig.fake.session.activationCount == activations)
    #expect(await rig.harness.uploader.completed.count == 1)
    await finish(rig)
  }

  @Test func aTakeThatIsNotResumedInTimeIsFinishedWithWhatItHas() async throws {
    let rig = try await makeRig(limit: 60)
    let id = try await refusedInBackground(rig)
    // The timer is armed just after the event; step the clock until it has fired.
    for _ in 0..<300 {
      if await rig.session.current.phase == .failed { break }
      await rig.harness.clock.advance(by: 61)
      try await Task.sleep(for: .milliseconds(10))
    }

    let state = await rig.session.current
    #expect(state.phase == .failed)
    #expect(state.failure == "recording was not resumed in time")
    let call = try #require(try await waitForCompletion(of: id, in: rig))
    #expect(call.segmentCount == 1)
    #expect(rig.events.entries(named: "audio.interruption").contains { $0.attributes["type"] == "resume_expired" })
    await finish(rig)
  }

  @Test func aRefusalWhileTheAppIsActiveStillFailsTheTake() async throws {
    let rig = try await makeRig()
    let id = try await rig.session.start(request)
    await rig.fake.record(seconds: 5)
    await rig.fake.session.deliver(.began)
    try await wait(.paused, in: rig.session)
    await rig.fake.session.failActivations(100, refused: true)
    await rig.fake.session.deliver(.ended(shouldResume: true))
    try await wait(.failed, in: rig.session)

    #expect(await rig.session.current.failure == "audio session could not be restored")
    #expect(try await waitForCompletion(of: id, in: rig)?.segmentCount == 1)
    await finish(rig)
  }

  @Test func anotherActivationFailureInTheBackgroundStillFailsTheTake() async throws {
    let rig = try await makeRig()
    let id = try await rig.session.start(request)
    await rig.fake.record(seconds: 5)
    await rig.fake.appActivity.setActive(false)
    await rig.fake.session.deliver(.began)
    try await wait(.paused, in: rig.session)
    await rig.fake.session.failActivations(100)
    await rig.fake.session.deliver(.ended(shouldResume: true))
    try await wait(.failed, in: rig.session)

    #expect(await rig.session.current.failure == "audio session could not be restored")
    #expect(try await waitForCompletion(of: id, in: rig)?.segmentCount == 1)
    await finish(rig)
  }

  @Test func theAppBecomingActiveNeverResumesATakeTheUserPaused() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    await rig.fake.record(seconds: 3)
    await rig.session.pause()
    await rig.fake.appActivity.setActive(false)
    await rig.fake.appActivity.setActive(true)
    try await Task.sleep(for: .milliseconds(80))

    #expect(await rig.session.current.phase == .paused)
    await rig.session.cancel()
    await finish(rig)
  }

  @Test func aUserResumeRefusedInTheBackgroundWaitsAndResumesWhenTheAppIsActive() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    await rig.fake.record(seconds: 3)
    await rig.session.pause()
    await rig.fake.appActivity.setActive(false)
    await rig.fake.session.failActivations(100, refused: true)
    await rig.session.resume()

    #expect(await rig.session.current.phase == .paused)
    #expect(await rig.session.current.failure == nil)
    try await waitForEvent("resume_deferred", in: rig)

    await rig.fake.session.failActivations(0)
    await rig.fake.appActivity.setActive(true)
    try await wait(.recording, in: rig.session)
    await rig.session.cancel()
    await finish(rig)
  }
}
