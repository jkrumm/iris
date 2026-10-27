import Foundation
import Testing

@testable import IrisCapture

struct TakeLifecycleTests {
  @Test func secondStopIsRejectedWhileTheFirstIsDraining() throws {
    var take = TakeLifecycle()
    try take.begin(memo(1))
    #expect(try take.beginStop() == memo(1))

    // The first stop is suspended on the sample drain; a double tap must not finalize again.
    #expect(throws: CaptureError.notRecording) { try take.beginStop() }
    #expect(take.activeMemoID == memo(1))  // samples still reach the open segment while draining
    #expect(take.isRecording == false)
  }

  @Test func startDuringAStopIsRejectedUntilTheStopFinishes() throws {
    var take = TakeLifecycle()
    try take.begin(memo(1))
    _ = try take.beginStop()
    #expect(throws: CaptureError.alreadyRecording) { try take.begin(memo(2)) }

    take.finishStop()
    try take.begin(memo(2))
    #expect(take.phase == .recording(memo(2)))
  }

  @Test func stopWithoutATakeAndDoubleStartAreRejected() throws {
    var take = TakeLifecycle()
    #expect(throws: CaptureError.notRecording) { try take.beginStop() }
    try take.begin(memo(1))
    #expect(throws: CaptureError.alreadyRecording) { try take.begin(memo(1)) }
  }

  @Test func abortedStartLeavesTheRecorderIdleAndRestartable() throws {
    var take = TakeLifecycle()
    try take.begin(memo(1))
    take.abortStart()
    #expect(take.phase == .idle)
    try take.begin(memo(2))
  }

  @Test func abortStartDoesNotCancelAStoppingTake() throws {
    var take = TakeLifecycle()
    try take.begin(memo(1))
    _ = try take.beginStop()
    take.abortStart()
    #expect(take.phase == .stopping(memo(1)))
  }
}

/// A `TapEngine` fake that models bus 0: installing a second tap crashes the real engine.
private final class FakeTapEngine: TapEngine {
  var tapInstalled = false
  var running = false
  var doubleInstalls = 0
  var failInstall = false
  var failStart = false
  private(set) var calls: [String] = []

  func removeTap() {
    calls.append("removeTap")
    tapInstalled = false
  }

  func installTap() throws {
    calls.append("installTap")
    if failInstall { throw CaptureError.engineFailure("install") }
    if tapInstalled { doubleInstalls += 1 }
    tapInstalled = true
  }

  func start() throws {
    calls.append("start")
    if failStart { throw CaptureError.engineFailure("start") }
    running = true
  }

  func stop() {
    calls.append("stop")
    running = false
  }
}

struct EngineStartupTests {
  @Test func successKeepsTheTapAndRunsTheEngine() throws {
    let engine = FakeTapEngine()
    try EngineStartup.bringUp(engine)
    #expect(engine.tapInstalled)
    #expect(engine.running)
  }

  @Test func failedEngineStartRemovesTheTapAndStopsTheEngine() {
    let engine = FakeTapEngine()
    engine.failStart = true
    #expect(throws: CaptureError.engineFailure("start")) { try EngineStartup.bringUp(engine) }
    #expect(engine.tapInstalled == false)
    #expect(engine.running == false)
    #expect(engine.calls.last == "stop")
  }

  @Test func failedTapInstallStopsTheEngineToo() {
    let engine = FakeTapEngine()
    engine.failInstall = true
    #expect(throws: CaptureError.engineFailure("install")) { try EngineStartup.bringUp(engine) }
    #expect(engine.tapInstalled == false)
    #expect(engine.running == false)
  }

  @Test func retryAfterAFailedStartNeverInstallsASecondTap() throws {
    let engine = FakeTapEngine()
    engine.failStart = true
    #expect(throws: CaptureError.engineFailure("start")) { try EngineStartup.bringUp(engine) }

    engine.failStart = false
    try EngineStartup.bringUp(engine)
    #expect(engine.doubleInstalls == 0)
    #expect(engine.tapInstalled)
    #expect(engine.running)
  }

  @Test func bringUpClearsAStaleTapBeforeInstalling() throws {
    let engine = FakeTapEngine()
    engine.tapInstalled = true  // left over from an earlier configuration
    try EngineStartup.bringUp(engine)
    #expect(engine.doubleInstalls == 0)
    #expect(engine.calls.first == "removeTap")
  }
}
