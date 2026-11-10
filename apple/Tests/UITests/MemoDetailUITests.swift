import XCTest

final class MemoDetailUITests: IrisUITestCase {
  @MainActor
  private func launch(holdCopied: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    // "Copied" lasts 1.5 s in the app; a loaded runner can query past that, so the copy test holds it for ten minutes and
    // asserts on a state it controls instead of racing the timer.
    app.launchArguments = SampleClock.arguments + (holdCopied ? ["-IrisCopiedSeconds", "600"] : [])
    start(app)
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["history.list"], timeout: 10))
    return app
  }

  /// Opens the History row whose label contains `text` (the list is scrolled until the row is on screen): a Hermes memo is a
  /// conversation, and its Details button opens the sheet this suite is about.
  @MainActor
  private func openRow(containing text: String, in app: XCUIApplication) {
    let row = revealRow(containing: text, in: app)
    row.tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["thread.view"], timeout: 10))
    let details = app.buttons["thread.turn.details"].firstMatch
    XCTAssertTrue(waitForPresence(details, timeout: 10))
    details.tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["memo.details"], timeout: 10))
  }

  /// Details start collapsed to their line; a tap on it opens the steps and the ids.
  @MainActor
  private func expandSteps(in app: XCUIApplication) {
    let toggle = app.buttons["detail.steps.toggle"]
    XCTAssertTrue(waitForPresence(toggle, timeout: 10))
    toggle.tap()
  }

  @MainActor
  func testDetailsAreCollapsedAndOpenOnTap() {
    let app = launch()
    openRow(containing: "Wochenplan abgestimmt", in: app)

    let toggle = app.buttons["detail.steps.toggle"]
    XCTAssertTrue(waitForPresence(toggle, timeout: 10))
    XCTAssertTrue(toggle.label.contains("Details"), "the line is the Details line: \(toggle.label)")
    XCTAssertTrue(waitForAbsence(app.staticTexts["Act · Hermes"], timeout: 2), "collapsed by default")

    XCTAssertTrue(waitForAbsence(app.descendants(matching: .any)["detail.ids"], timeout: 2), "the ids are in Details")

    toggle.tap()
    XCTAssertTrue(waitForPresence(app.staticTexts["Act · Hermes"], timeout: 5))
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["detail.ids"], timeout: 5))
    app.buttons["detail.steps.toggle"].tap()
    XCTAssertTrue(waitForAbsence(app.staticTexts["Act · Hermes"], timeout: 5))
  }

  @MainActor
  func testDetailsHaveCopyRowsForTranscriptAndReplyThatConfirm() {
    let app = launch(holdCopied: true)
    openRow(containing: "Wochenplan abgestimmt", in: app)
    expandSteps(in: app)

    let copy = app.buttons["detail.transcript.copy"]
    XCTAssertTrue(waitForPresence(copy, timeout: 10))
    copy.tap()
    let confirmed = app.buttons.matching(identifier: "detail.transcript.copy").matching(
      NSPredicate(format: "label == %@", "Copied")
    ).firstMatch
    XCTAssertTrue(waitForPresence(confirmed, timeout: 5), "the button says Copied: \(copy.label)")
  }

  @MainActor
  func testTheDetailsSheetShowsTheStepWaterfallAndThePlayer() {
    let app = launch()
    openRow(containing: "Wochenplan abgestimmt", in: app)

    expandSteps(in: app)
    XCTAssertTrue(waitForPresence(app.staticTexts["Act · Hermes"], timeout: 10))
    XCTAssertTrue(waitForPresence(app.staticTexts["Transcribe"], timeout: 2))
    XCTAssertTrue(waitForPresence(app.staticTexts["Notify"], timeout: 2))

    // The recording is a collapsed line in the user's bubble: no timeline until the chevron opens it.
    let toggle = app.buttons["detail.player.toggle"]
    XCTAssertTrue(waitForPresence(toggle, timeout: 5))
    XCTAssertTrue(waitForAbsence(app.buttons["detail.player.back"], timeout: 2), "collapsed by default")
    app.buttons["detail.player.expand"].tap()
    XCTAssertTrue(waitForPresence(app.buttons["detail.player.back"], timeout: 5))
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["detail.player.slider"], timeout: 2))

    // Play flips to Pause; skipping back at the start stays put and does not break the player.
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

    // A failed memo opens its waterfall on its own: the failed step and its retry are on screen.
    let stepRetry = app.buttons["detail.step.retry"]
    XCTAssertTrue(waitForPresence(stepRetry, timeout: 10))
    XCTAssertTrue(waitForPresence(app.staticTexts["hermes request failed: upstream 503"], timeout: 2))

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

    expandSteps(in: app)
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
