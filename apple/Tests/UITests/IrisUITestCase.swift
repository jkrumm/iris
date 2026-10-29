import XCTest

/// The base of every UI test. It owns how the app is started and ended.
///
/// "Failed to terminate com.jkrumm.iris" is a failure of the harness, not of a test's own steps. The hosted-runner log
/// that was captured (run 40829501216, `ReplyFlowReviewUITests`) shows it inside `XCUIApplication.launch()`: the
/// `Terminate com.jkrumm.iris:<pid>` line for the instance the previous test left running, ~55 s of silence on a loaded
/// VM, then the failure, charged to whichever test came next. The earlier flakes on `StatsSettingsUITests` and
/// `MemoDetailUITests` have the same shape (first launch of a class after another), but their logs were not kept, so
/// that part is an inference. No app-side hang was found: the app's own work is idle at that point.
///
/// So each test ends its own app at teardown, and a terminate that stalls is retried and reported as an expected failure
/// instead of failing a test that did nothing wrong. A real failure to start still fails (the third attempt is strict).
/// TDD §4 "UI tests on the hosted runner".
class IrisUITestCase: XCTestCase {
  private var started: [XCUIApplication] = []

  override func setUp() {
    continueAfterFailure = false
  }

  override func tearDown() {
    let apps = started
    started = []
    MainActor.assumeIsolated {
      for app in apps { Self.tolerateStalledTerminate { app.terminate() } }
    }
    super.tearDown()
  }

  /// Launches `app` and makes sure it ended with the test. Two tolerant attempts, then a strict one.
  @MainActor
  func start(_ app: XCUIApplication) {
    started.append(app)
    for _ in 0..<2 {
      Self.tolerateStalledTerminate { app.launch() }
      if app.state == .runningForeground { return }
      Self.tolerateStalledTerminate { app.terminate() }
    }
    app.launch()
  }

  /// Runs `work`; a "Failed to terminate" it reports is recorded as an expected failure, any other issue still fails.
  @MainActor
  private static func tolerateStalledTerminate(_ work: () -> Void) {
    XCTExpectFailure(
      "The simulator can stall while ending the app on a loaded runner", strict: false, failingBlock: work,
      issueMatcher: { $0.compactDescription.contains("Failed to terminate") })
  }
}
