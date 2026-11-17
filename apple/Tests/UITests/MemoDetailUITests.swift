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
  /// conversation, and the toolbar's Details button opens the sheet this suite is about.
  @MainActor
  private func openRow(containing text: String, in app: XCUIApplication) {
    let row = revealRow(containing: text, in: app)
    row.tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["thread.view"], timeout: 10))
    let details = app.buttons["thread.details"]
    XCTAssertTrue(waitForPresence(details, timeout: 10))
    details.tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["memo.details"], timeout: 10))
  }

  /// Details open on their steps and ids (whoever opened the sheet came for them); a tap on the Details line folds them and
  /// opens them again.
  @MainActor
  func testDetailsOpenOnTheStepsAndTheLineFoldsThem() {
    let app = launch()
    openRow(containing: "Wochenplan abgestimmt", in: app)

    let toggle = app.buttons["detail.steps.toggle"]
    XCTAssertTrue(waitForPresence(toggle, timeout: 10))
    XCTAssertTrue(toggle.label.contains("Details"), "the line is the Details line: \(toggle.label)")
    XCTAssertTrue(waitForPresence(app.staticTexts["Act · Hermes"], timeout: 5), "open by default")
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["detail.ids"], timeout: 5))

    toggle.tap()
    XCTAssertTrue(waitForAbsence(app.staticTexts["Act · Hermes"], timeout: 5))
    XCTAssertTrue(
      waitForAbsence(app.descendants(matching: .any)["detail.ids"], timeout: 2), "the ids fold with the steps")
    app.buttons["detail.steps.toggle"].tap()
    XCTAssertTrue(waitForPresence(app.staticTexts["Act · Hermes"], timeout: 5))
  }

  /// A conversation of two answers: the toolbar's Details opens on the newest one and steps back to the earlier.
  @MainActor
  func testTheToolbarOpensTheNewestAnswerAndStepsToTheEarlierOne() {
    let newestID = "c1a0b7d2-4e61-4f38-9a15-3d8e6b2f7c41"
    let earlierID = "c1a0b7d2-4e61-4f38-9a15-3d8e6b2f7c40"
    let app = launch()
    revealRow(containing: "Hang guards are not retried", in: app).tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["thread.view"], timeout: 10))
    let details = app.buttons["thread.details"]
    XCTAssertTrue(waitForPresence(details, timeout: 10))
    details.tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["memo.details"], timeout: 10))

    XCTAssertTrue(waitForPresence(app.staticTexts["Answer 2 of 2"], timeout: 5), "opens on the newest answer")
    XCTAssertTrue(waitForPresence(app.staticTexts[newestID], timeout: 5), "its memo id is the one on the page")
    XCTAssertFalse(app.buttons["memo.details.next"].isEnabled, "nothing after the newest")

    app.buttons["memo.details.previous"].tap()
    XCTAssertTrue(waitForPresence(app.staticTexts["Answer 1 of 2"], timeout: 5))
    XCTAssertTrue(waitForAbsence(app.staticTexts[newestID], timeout: 5), "the earlier answer has its own ids")
    XCTAssertFalse(app.buttons["memo.details.previous"].isEnabled, "nothing before the first")
    XCTAssertTrue(waitForPresence(app.staticTexts[earlierID], timeout: 5), "the earlier answer's own memo id")
  }

  /// A transcript memo's screen no longer carries Details inline: its toolbar opens them as the same sheet.
  @MainActor
  func testATranscriptScreenOpensDetailsFromItsToolbar() {
    let app = launch()
    revealRow(containing: "Nur ein Gedanke", in: app).tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["memo.detail"], timeout: 10))
    XCTAssertTrue(waitForAbsence(app.buttons["detail.steps.toggle"], timeout: 2), "no inline Details")

    let open = app.buttons["memo.details.open"]
    XCTAssertTrue(waitForPresence(open, timeout: 10))
    open.tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["memo.details"], timeout: 10))
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["detail.ids"], timeout: 5))
    XCTAssertTrue(waitForAbsence(app.buttons["memo.details.previous"], timeout: 1), "one memo, nothing to step to")
  }

  @MainActor
  func testDetailsHaveCopyRowsForTranscriptAndReplyThatConfirm() {
    let app = launch(holdCopied: true)
    openRow(containing: "Wochenplan abgestimmt", in: app)

    let copy = app.buttons["detail.transcript.copy"]
    XCTAssertTrue(waitForPresence(copy, timeout: 10))
    copy.tap()
    let confirmed = app.buttons.matching(identifier: "detail.transcript.copy").matching(
      NSPredicate(format: "label == %@", "Copied")
    ).firstMatch
    XCTAssertTrue(waitForPresence(confirmed, timeout: 5), "the button says Copied: \(copy.label)")
  }

  /// A transcript memo's screen leads with Copy transcript under the title: one tap puts the transcript on the pasteboard and the
  /// button confirms. The pasteboard is read through the app (paste into the composer): the test process itself gets `nil` from
  /// `UIPasteboard.general`, since a read across processes is blocked.
  @MainActor
  func testCopyTranscriptButtonPutsTheTranscriptOnThePasteboard() throws {
    let transcript = "Nur ein Gedanke für später: die Aufnahme beim Anruf nicht abbrechen, sondern pausieren."
    let app = launch(holdCopied: true)
    revealRow(containing: "Nur ein Gedanke", in: app).tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["memo.detail"], timeout: 10))

    let copy = app.buttons["detail.copy"]
    XCTAssertTrue(waitForPresence(copy, timeout: 10))
    XCTAssertEqual(copy.label, "Copy transcript")
    copy.tap()
    let confirmed = app.buttons.matching(identifier: "detail.copy").matching(
      NSPredicate(format: "label == %@", "Copied")
    ).firstMatch
    XCTAssertTrue(waitForPresence(confirmed, timeout: 5), "the button says Copied: \(copy.label)")

    // Back to History, open the composer from the record row and paste: the field holds what the button copied.
    app.navigationBars.buttons.element(boundBy: 0).tap()
    let text = app.descendants(matching: .any)["record.text"]
    XCTAssertTrue(waitForPresence(text, timeout: 10))
    text.tap()
    let field = app.textViews["composer.field"]
    XCTAssertTrue(waitForPresence(field, timeout: 10))
    field.tap()
    let paste = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Paste'")).firstMatch
    XCTAssertTrue(waitForPresence(paste, timeout: 10), "the pasteboard holds text, so the field offers Paste")
    paste.tap()
    let pasted = app.textViews["composer.field"].value as? String
    XCTAssertEqual(pasted, transcript)
  }

  @MainActor
  func testTheDetailsSheetShowsTheStepWaterfallAndThePlayer() {
    let app = launch()
    openRow(containing: "Wochenplan abgestimmt", in: app)

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

    // The failed step and its retry are on screen.
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
