import XCTest

/// The capture path on fakes: a voice take through the real outbox, and a memo that waits for the network.
final class CaptureUITests: IrisUITestCase {
  @MainActor
  private func launch(offline: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    // The offline note is a 5 s toast; a slow runner can poll past it, so the offline run keeps it for a minute.
    app.launchArguments = SampleClock.arguments + (offline ? ["-IrisFakeOffline", "-IrisUndoSeconds", "60"] : [])
    start(app)
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["history.list"], timeout: 10))
    return app
  }

  @MainActor
  private func label(_ app: XCUIApplication, containing text: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
  }

  /// Opens the seeded chat thread (its row is below the fold until the list has scrolled to it).
  @MainActor
  private func openChatThread(_ app: XCUIApplication) {
    let row = revealRow(containing: "How the step runner retries", in: app)
    row.tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["thread.view"], timeout: 10))
  }

  @MainActor
  func testAVoiceReplyIsRecordedUploadedProcessedAndAnswered() {
    let app = launch()
    openChatThread(app)

    // Hold to talk for a moment: the fake microphone feeds the real recorder pipeline, the outbox creates the memo,
    // uploads the segments and completes it.
    let pill = app.descendants(matching: .any)["thread.reply.voice"]
    XCTAssertTrue(waitForPresence(pill, timeout: 10))
    XCTAssertTrue(pill.isEnabled, "production-shaped capture is available under the fake stack")
    pill.press(forDuration: 1.5)

    // Processing: the answer replaces the pending turn. The fake answers fast and a hosted runner is slow, so the pending
    // turn itself is not asserted here (ThreadUITests and ReplyFlowReviewUITests run it on the slowed fake).
    XCTAssertTrue(waitForPresence(label(app, containing: "fake answer to your voice memo"), timeout: 30))
    XCTAssertTrue(waitForAbsence(app.descendants(matching: .any)["thread.turn.pending"], timeout: 5))

    // The outbox is empty again once the memo went up (the thread screen hides the tab bar: back to History first).
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["history.list"], timeout: 10))
    app.tabBars.buttons["Settings"].tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["settings.outbox.empty"], timeout: 10))
  }

  @MainActor
  func testAMemoTypedOfflineIsQueuedThenSentWithRetryNow() {
    let app = launch(offline: true)

    app.buttons["history.compose"].tap()
    app.buttons["Chat"].tap()
    let field = app.textViews["composer.field"]
    XCTAssertTrue(waitForPresence(field, timeout: 5))
    field.tap()
    field.typeText("Queued while offline")
    app.buttons["composer.send"].tap()

    // The first attempt fails: the sheet closes with a note, and the memo is not in History yet.
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["history.toast"], timeout: 10))
    XCTAssertTrue(waitForAbsence(app.buttons["composer.send"], timeout: 1))
    XCTAssertTrue(waitForAbsence(historyRow(containing: "Queued while offline", in: app), timeout: 2))

    // Settings shows it in the outbox, failed, with retry and discard.
    app.tabBars.buttons["Settings"].tap()
    let row = app.descendants(matching: .any)["settings.outbox.row"]
    XCTAssertTrue(waitForPresence(row, timeout: 10))
    XCTAssertTrue(row.label.contains("Queued while offline"))
    XCTAssertTrue(waitForPresence(app.buttons["settings.outbox.discard"], timeout: 2))
    app.buttons["settings.outbox.retry"].tap()

    // Sent: the queue is empty and the memo is in History.
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["settings.outbox.empty"], timeout: 10))
    app.tabBars.buttons["History"].tap()
    XCTAssertTrue(waitForPresence(historyRow(containing: "Queued while offline", in: app), timeout: 10))
  }
}
