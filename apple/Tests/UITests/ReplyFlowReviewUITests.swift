import XCTest

/// The reply flow of a thread, walked once per appearance with a screenshot attached at every step, for the owner's
/// async review (docs/design/README.md). The flow itself is asserted too, so the test is a regression check as well.
/// The fake API never answers a typed memo (it stays `transcribed`), so the text reply ends at its pending turn and the
/// revealed answer comes from the voice reply, whose fake pipeline walks to `notified`.
/// Export the PNGs with `scripts/reply-flow-shots.sh`.
final class ReplyFlowReviewUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// The appearance outlives the test on the simulator, and every UI test class that runs after this one expects light.
  override func tearDown() {
    MainActor.assumeIsolated { XCUIDevice.shared.appearance = .light }
  }

  @MainActor
  func testTextReplyLight() {
    textReply(appearance: .light, name: "light")
  }

  @MainActor
  func testTextReplyDark() {
    textReply(appearance: .dark, name: "dark")
  }

  @MainActor
  func testVoiceReplyLight() {
    voiceReply(appearance: .light, name: "light")
  }

  @MainActor
  func testVoiceReplyDark() {
    voiceReply(appearance: .dark, name: "dark")
  }

  /// Launches in `appearance` and opens the seeded chat thread: question, rendered answer, follow-up, the reply bar.
  @MainActor
  private func openThread(appearance: XCUIDevice.Appearance, name: String) -> XCUIApplication {
    XCUIDevice.shared.appearance = appearance

    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments
    app.launch()
    let list = app.descendants(matching: .any)["history.list"]
    XCTAssertTrue(list.waitForExistence(timeout: 10))

    let row = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == 'history.row' AND label CONTAINS %@", "How the step runner retries"))
      .firstMatch
    var scrolls = 0
    while !row.exists, scrolls < 8 {
      list.swipeUp()
      scrolls += 1
    }
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.scrollIntoClearBand(of: list, app: app)
    row.tap()

    XCTAssertTrue(app.descendants(matching: .any)["thread.view"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["And a hang guard, is that retried too?"].waitForExistence(timeout: 10))
    shot(name, "1-thread")
    return app
  }

  @MainActor
  private func textReply(appearance: XCUIDevice.Appearance, name: String) {
    let app = openThread(appearance: appearance, name: name)

    // The composer is bound to the thread (no mode chips).
    app.buttons["thread.reply.text"].tap()
    let field = app.textViews["composer.field"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText("What about the narrow table?")
    shot(name, "2-text-composer")

    // Sent: the typed turn joins the thread with a pending answer.
    app.buttons["composer.send"].tap()
    XCTAssertTrue(app.staticTexts["What about the narrow table?"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.descendants(matching: .any)["thread.turn.pending"].waitForExistence(timeout: 10))
    shot(name, "3-text-pending")
  }

  @MainActor
  private func voiceReply(appearance: XCUIDevice.Appearance, name: String) {
    let app = openThread(appearance: appearance, name: name)

    // Hold to talk: the fake microphone feeds the real recorder pipeline, the outbox uploads and completes the memo.
    let pill = app.descendants(matching: .any)["thread.reply.voice"]
    XCTAssertTrue(pill.waitForExistence(timeout: 10))
    XCTAssertTrue(pill.isEnabled)
    pill.press(forDuration: 1.5)

    // The voice turn shows pending, then the answer replaces it.
    let pending = app.descendants(matching: .any)["thread.turn.pending"]
    XCTAssertTrue(pending.waitForExistence(timeout: 10))
    shot(name, "4-voice-pending")

    let answer = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "fake answer to your voice memo")).firstMatch
    XCTAssertTrue(answer.waitForExistence(timeout: 20))
    XCTAssertTrue(pending.waitForNonExistence(timeout: 10))
    shot(name, "5-voice-answer")
  }

  @MainActor
  private func shot(_ appearance: String, _ step: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "reply-flow-\(step)-\(appearance)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
