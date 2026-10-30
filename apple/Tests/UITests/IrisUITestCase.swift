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
///
/// "Failed to get matching snapshots: Timed out while evaluating UI query" is the same kind of harness failure: a query for
/// an element's attributes is a snapshot of the whole accessibility tree, and on a loaded VM (an animating History list, a
/// thread with a rendered answer) the app does not answer in time. It hit `ReplyFlowReviewUITests` and
/// `CaptureUITests` at a bare `row.exists` (run 41017094962). Every wait and every probe of a test therefore goes through
/// ``waitForPresence(_:timeout:)``, ``waitForAbsence(_:timeout:)`` and ``revealRow(containing:in:)`` below: they ask again until
/// the deadline when a query times out, instead of failing at the first one. A bare `exists`/`frame` read of an element that
/// may not be there yet, in a loop, is what to avoid in a test.
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

  // MARK: Queries on a busy hierarchy

  /// Waits for `element` to exist. A query that times out on a loaded runner is asked again until `timeout` is over, so the
  /// only way to fail is an element that is really not there.
  @MainActor
  func waitForPresence(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      let slice = min(5, max(deadline.timeIntervalSinceNow, 0.5))
      if QueryRetry.attempt({ element.waitForExistence(timeout: slice) }) == true { return true }
    } while Date() < deadline
    return false
  }

  /// Waits for `element` to be gone, asking again when a query times out.
  @MainActor
  func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      let slice = min(5, max(deadline.timeIntervalSinceNow, 0.5))
      if QueryRetry.attempt({ element.waitForNonExistence(timeout: slice) }) == true { return true }
    } while Date() < deadline
    return false
  }

  /// The History row whose label contains `text`.
  @MainActor
  func historyRow(containing text: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == 'history.row' AND label CONTAINS %@", text)).firstMatch
  }

  /// Scrolls History until the row whose label contains `text` is in the tree (the list is lazy: a row below the fold is not
  /// there until it is scrolled to) and then into the clear band, ready to tap.
  @MainActor
  func revealRow(containing text: String, in app: XCUIApplication) -> XCUIElement {
    let row = historyRow(containing: text, in: app)
    let list = app.descendants(matching: .any)["history.list"]
    var scrolls = 0
    while !waitForPresence(row, timeout: 2), scrolls < 8 {
      list.swipeUp()
      scrolls += 1
    }
    XCTAssertTrue(waitForPresence(row, timeout: 10), "no History row containing \(text)")
    row.scrollIntoClearBand(of: list, app: app)
    return row
  }

  /// Runs `work`; a "Failed to terminate" it reports is recorded as an expected failure, any other issue still fails.
  @MainActor
  private static func tolerateStalledTerminate(_ work: () -> Void) {
    XCTExpectFailure(
      "The simulator can stall while ending the app on a loaded runner", strict: false, failingBlock: work,
      issueMatcher: { $0.compactDescription.contains("Failed to terminate") })
  }
}

/// Asks a UI query again instead of failing the test when the app did not answer it in time.
enum QueryRetry {
  /// The result of `body`, or `nil` when a query inside it timed out (any other failure still fails the test).
  @MainActor
  static func attempt<T>(_ body: () -> T) -> T? {
    var result: T?
    XCTExpectFailure(
      "A query can time out while a loaded runner animates the app", strict: false,
      failingBlock: { result = body() },
      issueMatcher: { $0.compactDescription.contains("Timed out while evaluating UI query") })
    return result
  }
}
