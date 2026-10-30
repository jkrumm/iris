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

struct EngineResumeTests {
  @Test func aPausedEngineThatRestartsIsKept() throws {
    let engine = FakeTapEngine()
    try EngineStartup.bringUp(engine)
    var replacements = 0
    let resumed = try EngineStartup.resume(engine) {
      replacements += 1
      return FakeTapEngine()
    }
    #expect(resumed === engine)
    #expect(replacements == 0)
  }

  @Test func anEngineThatWillNotRestartIsReplacedByAFreshOneWithTheTap() throws {
    let stale = FakeTapEngine()
    try EngineStartup.bringUp(stale)
    stale.failStart = true
    let fresh = FakeTapEngine()
    let resumed = try EngineStartup.resume(stale) { fresh }
    #expect(resumed === fresh)
    #expect(fresh.tapInstalled)
    #expect(fresh.running)
    #expect(stale.tapInstalled == false, "the dead engine gives up bus 0")
    #expect(stale.running == false)
  }

  @Test func aFreshEngineThatFailsToo_throwsAndLeavesNothingRunning() {
    let stale = FakeTapEngine()
    stale.failStart = true
    let fresh = FakeTapEngine()
    fresh.failStart = true
    #expect(throws: CaptureError.engineFailure("start")) { try EngineStartup.resume(stale) { fresh } }
    #expect(fresh.tapInstalled == false)
    #expect(fresh.running == false)
  }
}

struct EngineRecoveryTests {
  @Test func aConfigurationChangeIsAnsweredByAFreshEngineWithTheTapAndTheOldOneGivesUpBusZero() async throws {
    let old = FakeTapEngine()
    try EngineStartup.bringUp(old)
    let fresh = FakeTapEngine()
    let recovered = try await EngineStartup.recover(old, replacement: { fresh }, attempts: 3, pause: { true })
    #expect(recovered === fresh)
    #expect(fresh.tapInstalled && fresh.running)
    #expect(old.tapInstalled == false && old.running == false)
  }

  @Test func anInputThatIsNotReadyYetIsRetriedUntilItIs() async throws {
    // AirPods report no format while the Bluetooth link comes up: the first installs fail, the third holds.
    let engines = [FakeTapEngine(), FakeTapEngine(), FakeTapEngine()]
    engines[0].failInstall = true
    engines[1].failInstall = true
    var made = 0
    var pauses = 0
    let recovered = try await EngineStartup.recover(
      FakeTapEngine(),
      replacement: {
        defer { made += 1 }
        return engines[made]
      }, attempts: 6,
      pause: {
        pauses += 1
        return true
      })
    #expect(recovered === engines[2])
    #expect(pauses == 2)
    #expect(engines[0].tapInstalled == false && engines[1].tapInstalled == false)
  }

  @Test func anInputThatNeverComesBackThrowsAfterTheLastAttempt() async {
    var made = 0
    var pauses = 0
    await #expect(throws: CaptureError.engineFailure("install")) {
      try await EngineStartup.recover(
        FakeTapEngine(),
        replacement: {
          made += 1
          let engine = FakeTapEngine()
          engine.failInstall = true
          return engine
        }, attempts: 4,
        pause: {
          pauses += 1
          return true
        })
    }
    #expect(made == 4)
    #expect(pauses == 3, "no wait after the last attempt")
  }

  @Test func aTakeThatEndedWhileWaitingAbandonsTheRestartWithoutAnEngine() async throws {
    var made = 0
    let recovered = try await EngineStartup.recover(
      FakeTapEngine(),
      replacement: {
        made += 1
        let engine = FakeTapEngine()
        engine.failInstall = true
        return engine
      }, attempts: 6, pause: { false })
    #expect(recovered == nil)
    #expect(made == 1)
  }
}

struct EngineRunTests {
  private func recording() -> EngineRun {
    var run = EngineRun()
    run.begin()
    return run
  }

  @Test func pauseAndResumeInsideARestartNeverTouchTheTornDownEngine() {
    var run = recording()
    let token = run.beginRestart()
    #expect(run.pause() == .none, "the old engine is gone; there is nothing to pause")
    #expect(run.isPaused)
    #expect(run.resume() == .none, "and nothing to start: the restart brings the engine up")
    #expect(run.isPaused == false)
    #expect(run.endRestart(token) == .keepRunning)
  }

  @Test func aPauseThatLandsInsideARestartIsAppliedToTheNewEngine() {
    var run = recording()
    let token = run.beginRestart()
    #expect(run.pause() == .none)
    #expect(run.endRestart(token) == .keepPaused)
    #expect(run.isRestarting == false)
  }

  @Test func outsideARestartPauseAndResumeActOnTheEngine() {
    var run = recording()
    #expect(run.pause() == .pauseEngine)
    #expect(run.resume() == .startEngine)
    #expect(run.isPaused, "a start that fails keeps the take paused until it is confirmed")
    run.resumed()
    #expect(run.isPaused == false)
  }

  @Test func aRestartThatOutlivesItsTakeIsDiscarded() {
    var run = recording()
    let token = run.beginRestart()
    run.end()
    #expect(run.isRestarting == false)
    #expect(run.endRestart(token) == .discard)
  }

  @Test func aRestartOfAnEarlierTakeCannotTouchTheNextOne() {
    var run = recording()
    let stale = run.beginRestart()
    run.end()
    run.begin()
    let current = run.beginRestart()
    #expect(run.endRestart(stale) == .discard)
    #expect(run.isRestarting, "the stale restart did not end the new take's")
    #expect(run.endRestart(current) == .keepRunning)
  }
}
