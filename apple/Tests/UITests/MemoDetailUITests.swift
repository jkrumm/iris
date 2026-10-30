import XCTest

final class MemoDetailUITests: IrisUITestCase {
  @MainActor
  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments
    start(app)
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["history.list"], timeout: 10))
    return app
  }

  /// Opens the History row whose label contains `text`; the list is scrolled until the row is on screen.
  @MainActor
  private func openRow(containing text: String, in app: XCUIApplication) {
    let row = revealRow(containing: text, in: app)
    row.tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["memo.detail"], timeout: 10))
  }

  @MainActor
  func testDetailShowsTheStepWaterfallTranscriptAndPlayer() {
    let app = launch()
    openRow(containing: "Wochenplan abgestimmt", in: app)

    XCTAssertTrue(waitForPresence(app.staticTexts["Act · Hermes"], timeout: 10))
    XCTAssertTrue(waitForPresence(app.staticTexts["Transcribe"], timeout: 2))
    XCTAssertTrue(waitForPresence(app.staticTexts["Notify"], timeout: 2))
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["detail.transcript"], timeout: 2))

    // Play flips to Pause; skipping back at the start stays put and does not break the player.
    let toggle = app.buttons["detail.player.toggle"]
    XCTAssertTrue(waitForPresence(toggle, timeout: 5))
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
    XCTAssertTrue(waitForPresence(stepRetry, timeout: 10))
    XCTAssertTrue(waitForPresence(app.staticTexts["agw job failed: upstream 503"], timeout: 2))

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

    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["detail.step.optional"], timeout: 10))
    XCTAssertTrue(waitForPresence(app.staticTexts["agw triage failed: 402 payment required"], timeout: 2))
    XCTAssertTrue(waitForPresence(app.staticTexts["Notify"], timeout: 2), "the steps after the skipped one still ran")

    let stepRetry = app.buttons["detail.step.retry"]
    XCTAssertTrue(waitForPresence(stepRetry, timeout: 10))
    stepRetry.tap()
    let gone = NSPredicate(format: "exists == false")
    expectation(for: gone, evaluatedWith: stepRetry)
    waitForExpectations(timeout: 10)
  }
}
