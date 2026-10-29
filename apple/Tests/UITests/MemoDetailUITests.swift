import XCTest

final class MemoDetailUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["history.list"].waitForExistence(timeout: 10))
    return app
  }

  /// Opens the History row whose label contains `text`; the list is scrolled until the row is on screen.
  @MainActor
  private func openRow(containing text: String, in app: XCUIApplication) {
    let row = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == 'history.row' AND label CONTAINS %@", text)).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    let list = app.descendants(matching: .any)["history.list"]
    var attempts = 0
    while !row.isHittable, attempts < 5 {
      list.swipeUp()
      attempts += 1
    }
    row.tap()
    XCTAssertTrue(app.descendants(matching: .any)["memo.detail"].waitForExistence(timeout: 10))
  }

  @MainActor
  func testDetailShowsTheStepWaterfallTranscriptAndPlayer() {
    let app = launch()
    openRow(containing: "Wochenplan abgestimmt", in: app)

    XCTAssertTrue(app.staticTexts["Act · Hermes"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Transcribe"].exists)
    XCTAssertTrue(app.staticTexts["Notify"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["detail.transcript"].exists)

    // Play flips to Pause; skipping back at the start stays put and does not break the player.
    let toggle = app.buttons["detail.player.toggle"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    XCTAssertEqual(toggle.label, "Play")
    toggle.tap()
    XCTAssertEqual(app.buttons["detail.player.toggle"].label, "Pause")
    app.buttons["detail.player.back"].tap()
    app.buttons["detail.player.toggle"].tap()
    XCTAssertEqual(app.buttons["detail.player.toggle"].label, "Play")
  }

  @MainActor
  func testRetryFromTheFailedStepLeavesTheFailedState() {
    let app = launch()
    openRow(containing: "xcodegen", in: app)

    let stepRetry = app.buttons["detail.step.retry"]
    XCTAssertTrue(stepRetry.waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["agw job failed: upstream 503"].exists)

    // The bottom retry icon restarts from the step that failed; the fake server then reports the memo as received.
    app.buttons["detail.action.retry"].tap()
    let gone = NSPredicate(format: "exists == false")
    expectation(for: gone, evaluatedWith: stepRetry)
    waitForExpectations(timeout: 10)
  }
}
