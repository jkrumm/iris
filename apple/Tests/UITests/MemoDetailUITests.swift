import XCTest

final class MemoDetailUITests: IrisUITestCase {
  @MainActor
  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments
    start(app)
    XCTAssertTrue(app.descendants(matching: .any)["history.list"].waitForExistence(timeout: 10))
    return app
  }

  /// Opens the History row whose label contains `text`; the list is scrolled until the row is on screen.
  @MainActor
  private func openRow(containing text: String, in app: XCUIApplication) {
    let row = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == 'history.row' AND label CONTAINS %@", text)).firstMatch
    let list = app.descendants(matching: .any)["history.list"]
    // The list is lazy: a row below the fold is not in the tree until it is scrolled to.
    var scrolls = 0
    while !row.exists, scrolls < 8 {
      list.swipeUp()
      scrolls += 1
    }
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.scrollIntoClearBand(of: list, app: app)
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

  /// The sample memo that finished without a summary: its headline is the clipped transcript, the summarize step reads as
  /// optional, and the step's retry brings the memo back to `acted` on the fake server (the step row goes away).
  @MainActor
  func testAFailedSummarizeOnAFinishedMemoIsOptionalAndRetryable() {
    let app = launch()
    openRow(containing: "Erinnere mich bitte daran, am Montag", in: app)

    XCTAssertTrue(app.descendants(matching: .any)["detail.step.optional"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["agw triage failed: 402 payment required"].exists)
    XCTAssertTrue(app.staticTexts["Notify"].exists, "the steps after the skipped one still ran")

    let stepRetry = app.buttons["detail.step.retry"]
    XCTAssertTrue(stepRetry.waitForExistence(timeout: 10))
    stepRetry.tap()
    let gone = NSPredicate(format: "exists == false")
    expectation(for: gone, evaluatedWith: stepRetry)
    waitForExpectations(timeout: 10)
  }
}
