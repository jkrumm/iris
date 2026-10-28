import XCTest

/// The capture path on fakes: a voice take through the real outbox, and a memo that waits for the network.
final class CaptureUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launch(offline: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-IrisFakeCapture"] + (offline ? ["-IrisFakeOffline"] : [])
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["history.list"].waitForExistence(timeout: 10))
    return app
  }

  @MainActor
  private func label(_ app: XCUIApplication, containing text: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
  }

  /// Opens the seeded chat thread (its row is below the fold until the list has scrolled to it).
  @MainActor
  private func openChatThread(_ app: XCUIApplication) {
    let row = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == 'history.row' AND label CONTAINS %@", "How the step runner retries"))
      .firstMatch
    let list = app.descendants(matching: .any)["history.list"]
    var scrolls = 0
    while !row.exists, scrolls < 8 {
      list.swipeUp()
      scrolls += 1
    }
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    var attempts = 0
    while !row.isHittable, attempts < 8 {
      list.swipeUp()
      attempts += 1
    }
    row.tap()
    XCTAssertTrue(app.descendants(matching: .any)["thread.view"].waitForExistence(timeout: 10))
  }

  @MainActor
  func testAVoiceReplyIsRecordedUploadedProcessedAndAnswered() {
    let app = launch()
    openChatThread(app)

    // Hold to talk for a moment: the fake microphone feeds the real recorder pipeline, the outbox creates the memo,
    // uploads the segments and completes it.
    let pill = app.descendants(matching: .any)["thread.reply.voice"]
    XCTAssertTrue(pill.waitForExistence(timeout: 10))
    XCTAssertTrue(pill.isEnabled, "production-shaped capture is available under the fake stack")
    pill.press(forDuration: 1.5)

    // Processing: the pending turn with the step dashes, then the answer replaces it.
    XCTAssertTrue(app.descendants(matching: .any)["thread.turn.pending"].waitForExistence(timeout: 10))
    XCTAssertTrue(label(app, containing: "fake answer to your voice memo").waitForExistence(timeout: 20))
    XCTAssertFalse(app.descendants(matching: .any)["thread.turn.pending"].exists)

    // The outbox is empty again once the memo went up (the thread screen hides the tab bar: back to History first).
    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.descendants(matching: .any)["history.list"].waitForExistence(timeout: 10))
    app.tabBars.buttons["Settings"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["settings.outbox.empty"].waitForExistence(timeout: 10))
  }

  @MainActor
  func testAMemoTypedOfflineIsQueuedThenSentWithRetryNow() {
    let app = launch(offline: true)

    app.buttons["history.compose"].tap()
    app.buttons["Chat"].tap()
    let field = app.textViews["composer.field"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText("Queued while offline")
    app.buttons["composer.send"].tap()

    // The first attempt fails: the sheet closes with a note, and the memo is not in History yet.
    XCTAssertTrue(app.descendants(matching: .any)["history.toast"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["composer.send"].exists)
    XCTAssertFalse(
      app.descendants(matching: .any)
        .matching(NSPredicate(format: "identifier == 'history.row' AND label CONTAINS %@", "Queued while offline"))
        .firstMatch.exists)

    // Settings shows it in the outbox, failed, with retry and discard.
    app.tabBars.buttons["Settings"].tap()
    let row = app.descendants(matching: .any)["settings.outbox.row"]
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    XCTAssertTrue(row.label.contains("Queued while offline"))
    XCTAssertTrue(app.buttons["settings.outbox.discard"].exists)
    app.buttons["settings.outbox.retry"].tap()

    // Sent: the queue is empty and the memo is in History.
    XCTAssertTrue(app.descendants(matching: .any)["settings.outbox.empty"].waitForExistence(timeout: 10))
    app.tabBars.buttons["History"].tap()
    let sent = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == 'history.row' AND label CONTAINS %@", "Queued while offline"))
      .firstMatch
    XCTAssertTrue(sent.waitForExistence(timeout: 10))
  }
}
