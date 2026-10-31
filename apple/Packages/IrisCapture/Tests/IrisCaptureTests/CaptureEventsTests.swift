import Foundation
import Testing

@testable import IrisCapture

struct CaptureEventsTests {
  private struct Rig {
    let session: CaptureSession
    let fake: FakeCapture
    let harness: OutboxHarness
    let events: RecordingCaptureEvents
    let directory: URL
  }

  private func makeRig() async throws -> Rig {
    let directory = try temporaryDirectory()
    let harness = try await OutboxHarness()
    let fake = FakeCapture(directory: directory, clock: harness.clock)
    let events = RecordingCaptureEvents()
    let session = CaptureSession(
      session: fake.session, routes: fake.routes, recorder: fake.recorder, outbox: harness.outbox,
      clock: harness.clock, events: events)
    return Rig(session: session, fake: fake, harness: harness, events: events, directory: directory)
  }

  private func finish(_ rig: Rig) async {
    await rig.session.shutdown()
    await rig.harness.outbox.shutdown()
    try? FileManager.default.removeItem(at: rig.directory)
  }

  private func waitForPhase(_ phase: TakePhase, in session: CaptureSession) async throws {
    for _ in 0..<200 {
      if await session.current.phase == phase { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("never reached \(phase)")
  }

  private let request = TakeRequest(mode: "auto", title: "Voice memo")

  @Test func aTakeIsATimelineOfPhasesSegmentsAndAStopForItsMemo() async throws {
    let rig = try await makeRig()
    let id = try await rig.session.start(request)
    await rig.fake.record(seconds: 12)
    _ = try await rig.session.stop()
    await rig.harness.outbox.settled()

    let phases = rig.events.entries(named: "take.phase")
    #expect(phases.map { $0.attributes["phase"] } == ["starting", "recording", "stopping", "stopped"])
    #expect(phases.allSatisfy { $0.memoID == id })
    #expect(phases.dropFirst().first?.attributes["mode"] == "auto")

    let segments = rig.events.entries(named: "capture.segment.closed")
    #expect(segments.map { $0.attributes["index"] } == [0, 1])
    #expect(segments.map { $0.attributes["reason"] } == ["rotate", "stop"])
    #expect(segments.allSatisfy { $0.memoID == id && $0.attributes["closed_ok"] == true })
    await finish(rig)
  }

  @Test func aPhaseThatDoesNotChangeIsNotReportedAgain() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    await rig.fake.record(seconds: 1)
    await rig.session.cancel()

    let phases = rig.events.entries(named: "take.phase").map { $0.attributes["phase"] }
    #expect(phases == ["starting", "recording", "stopping", "stopped"])
    await finish(rig)
  }

  @Test func anInterruptionIsPausedThenAResumeWithItsResultAndTheGapBetween() async throws {
    let rig = try await makeRig()
    let id = try await rig.session.start(request)
    await rig.fake.record(seconds: 2)
    await rig.fake.interrupt()
    try await waitForPhase(.paused, in: rig.session)
    await rig.harness.clock.advance(by: 4)
    await rig.fake.endInterruption(shouldResume: true)
    try await waitForPhase(.recording, in: rig.session)
    await rig.session.cancel()

    let gap = try #require(rig.events.entries(named: "capture.gap").first)
    #expect(gap.memoID == id)
    #expect(gap.attributes["reason"] == "interruption")
    #expect(gap.attributes["ms"] == 4000)
    #expect(gap.attributes["frames_lost"] == 64_000, "4 s at the 16 kHz capture rate")
    let resume = rig.events.entries(named: "audio.interruption").first { $0.attributes["type"] == "resume" }
    #expect(resume?.attributes["resume.result"] == "ok")
    await finish(rig)
  }

  @Test func anInterruptionThatDoesNotRecommendResumingSaysSoInsteadOfLeavingSilence() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    await rig.fake.interrupt()
    try await waitForPhase(.paused, in: rig.session)
    await rig.fake.endInterruption(shouldResume: false)
    try await Task.sleep(for: .milliseconds(50))

    let skipped = try #require(rig.events.entries(named: "audio.interruption").first)
    #expect(skipped.attributes["type"] == "resume_skipped")
    #expect(skipped.attributes["should_resume"] == false)
    #expect(rig.events.entries(named: "capture.gap").isEmpty, "still paused: the gap is open")
    await rig.session.cancel()
    await finish(rig)
  }

  @Test func aUserPauseIsAGapWithItsOwnReason() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    await rig.session.pause()
    await rig.harness.clock.advance(by: 1.5)
    await rig.session.resume()

    let gap = try #require(rig.events.entries(named: "capture.gap").first)
    #expect(gap.attributes["reason"] == "pause")
    #expect(gap.attributes["ms"] == 1500)
    await rig.session.cancel()
    await finish(rig)
  }

  @Test func aRecorderFailureIsAnErrorLevelPhase() async throws {
    let rig = try await makeRig()
    try await rig.session.start(request)
    await rig.fake.record(seconds: 1)
    await rig.fake.recorder.fail(reason: "segment write failed")
    try await waitForPhase(.failed, in: rig.session)

    let failed = try #require(rig.events.entries(named: "take.phase").first { $0.attributes["phase"] == "failed" })
    #expect(failed.error)
    #expect(failed.attributes["failure"] == "segment write failed")
    await rig.session.cancel()
    await finish(rig)
  }
}

struct FourCCTests {
  @Test(arguments: [
    (561_145_187, "!rec"), (560_557_684, "!int"), (561_015_905, "!pla"), (561_017_449, "!pri"),
  ])
  func decodesTheCodesTheAudioFrameworksDocument(code: Int, text: String) {
    #expect(FourCC.string(from: code) == text)
  }

  @Test(arguments: [0, -50, 7, 1_000_000_000_000])
  func aCodeThatIsNotFourPrintableCharactersHasNoSpelling(code: Int) {
    #expect(FourCC.string(from: code) == nil)
  }

  @Test func errorDetailCarriesDomainCodeAndSpelling() {
    let error = NSError(domain: NSOSStatusErrorDomain, code: 561_145_187)
    let attributes = CaptureErrorDetail.attributes(of: error)
    #expect(attributes["error.domain"] == .string(NSOSStatusErrorDomain))
    #expect(attributes["error.code"] == 561_145_187)
    #expect(attributes["error.fourcc"] == "!rec")
  }
}

struct LevelReporterTests {
  @Test func reportsTwiceASecondAtTheCaptureRate() {
    var reporter = LevelReporter(sampleRate: 16_000)
    var reports = 0
    for _ in 0..<10 {  // ten 4096-frame buffers: 40 960 frames, 2.56 s
      if reporter.add([Float](repeating: 0.1, count: 4096)) != nil { reports += 1 }
    }
    #expect(reports == 5)
  }

  @Test func rmsAndPeakAreInDecibelsFullScale() throws {
    var reporter = LevelReporter(sampleRate: 100)
    let samples: [Float] = (0..<50).map { $0 == 0 ? 0.5 : 0.1 }
    let reported = reporter.add(samples)
    let level = try #require(reported)
    #expect(level.peakDecibels == -6.0)
    #expect(abs(level.rmsDecibels - -18.3) < 0.1)
  }

  @Test func silenceIsTheFloorNotMinusInfinity() throws {
    var reporter = LevelReporter(sampleRate: 100)
    let reported = reporter.add([Float](repeating: 0, count: 50))
    let level = try #require(reported)
    #expect(level.rmsDecibels == -120)
    #expect(level.peakDecibels == -120)
  }
}
