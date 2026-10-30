import XCTest

/// The reply flow of a thread, walked once per appearance with a screenshot attached at every step, for the owner's
/// async review (docs/design/README.md). The flow itself is asserted too, so the test is a regression check as well.
/// The fake pipeline answers a typed memo as it does a voice one, so the text reply runs to its answer too.
/// Export the PNGs with `scripts/reply-flow-shots.sh`.
final class ReplyFlowReviewUITests: IrisUITestCase {
  /// The appearance outlives the test on the simulator, and every UI test class that runs after this one expects light.
  override func tearDown() {
    // The app ends first: switching appearance under a running app is what the next launch would have to terminate.
    super.tearDown()
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

  @MainActor
  func testLockedRecordingLight() {
    lockedRecording(appearance: .light, name: "light")
  }

  @MainActor
  func testLockedRecordingDark() {
    lockedRecording(appearance: .dark, name: "dark")
  }

  /// Launches in `appearance` and opens the seeded chat thread: question, rendered answer, follow-up, the reply bar.
  @MainActor
  private func openThread(appearance: XCUIDevice.Appearance, name: String) -> XCUIApplication {
    XCUIDevice.shared.appearance = appearance

    let app = XCUIApplication()
    // A slower fake server, so the pending turn is still there when the screenshot is taken.
    app.launchArguments = SampleClock.arguments + ["-IrisFakeStepMs", "3000"]
    start(app)
    let list = app.descendants(matching: .any)["history.list"]
    XCTAssertTrue(waitForPresence(list, timeout: 10))

    let row = revealRow(containing: "How the step runner retries", in: app)
    row.tap()

    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["thread.view"], timeout: 10))
    XCTAssertTrue(waitForPresence(app.staticTexts["And a hang guard, is that retried too?"], timeout: 10))
    shot(name, "1-thread")
    return app
  }

  @MainActor
  private func textReply(appearance: XCUIDevice.Appearance, name: String) {
    let app = openThread(appearance: appearance, name: name)

    // The composer is bound to the thread (no mode chips).
    app.buttons["thread.reply.text"].tap()
    let field = app.textViews["composer.field"]
    XCTAssertTrue(waitForPresence(field, timeout: 5))
    field.tap()
    field.typeText("What about the narrow table?")
    shot(name, "2-text-composer")

    // Sent: the typed turn joins the thread with a pending answer, then the answer replaces it.
    app.buttons["composer.send"].tap()
    XCTAssertTrue(waitForPresence(app.staticTexts["What about the narrow table?"], timeout: 10))
    let pending = app.descendants(matching: .any)["thread.turn.pending"]
    let answer = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "fake answer to your message")).firstMatch
    if awaitPending(pending, orAnswer: answer) { shot(name, "3-text-pending") }
    XCTAssertTrue(waitForPresence(answer, timeout: 30))
    XCTAssertTrue(waitForAbsence(pending, timeout: 10))
    shot(name, "3b-text-answer")
  }

  @MainActor
  private func voiceReply(appearance: XCUIDevice.Appearance, name: String) {
    let app = openThread(appearance: appearance, name: name)

    // Hold to talk: the fake microphone feeds the real recorder pipeline, the outbox uploads and completes the memo.
    let pill = app.descendants(matching: .any)["thread.reply.voice"]
    XCTAssertTrue(waitForPresence(pill, timeout: 10))
    XCTAssertTrue(pill.isEnabled)
    pill.press(forDuration: 1.5)

    // The voice turn shows pending, then the answer replaces it.
    let pending = app.descendants(matching: .any)["thread.turn.pending"]
    let answer = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "fake answer to your voice memo")).firstMatch
    if awaitPending(pending, orAnswer: answer) { shot(name, "4-voice-pending") }
    XCTAssertTrue(waitForPresence(answer, timeout: 30))
    XCTAssertTrue(waitForAbsence(pending, timeout: 10))
    shot(name, "5-voice-answer")
  }

  /// The locked recording: a tap starts a take bound to the thread, it keeps recording without a finger, the send button ends it.
  @MainActor
  private func lockedRecording(appearance: XCUIDevice.Appearance, name: String) {
    let app = openThread(appearance: appearance, name: name)

    let lock = app.buttons["thread.reply.lock"]
    XCTAssertTrue(waitForPresence(lock, timeout: 10))
    lock.tap()
    let send = app.buttons["thread.reply.lock.send"]
    XCTAssertTrue(waitForPresence(send, timeout: 5))
    XCTAssertTrue(waitForPresence(app.buttons["thread.reply.lock.cancel"], timeout: 2))
    // Long enough to pass the minimum take (0.8 s), with no finger on the screen.
    sleep(1)
    shot(name, "6-locked-recording")

    send.tap()
    // The fake answers fast and a hosted runner is slow: the pending turn may be gone before it is queried, so the answer is what counts.
    let answer = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "fake answer to your voice memo")).firstMatch
    XCTAssertTrue(waitForPresence(answer, timeout: 30))
    XCTAssertTrue(waitForPresence(app.buttons["thread.reply.lock"], timeout: 5))
  }

  /// Waits for the pending turn, which the slowed fake keeps up for several seconds, or for the answer when it replaced it
  /// already. `true` when the pending turn was seen (a runner that was too slow to catch it is not a failure: the answer stands
  /// in), so a render of the pending state is taken only when there is one.
  @MainActor
  private func awaitPending(_ pending: XCUIElement, orAnswer answer: XCUIElement) -> Bool {
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
      if presence(of: pending, within: 1) == true { return true }
      if presence(of: answer, within: 1) == true { return false }
    }
    return false
  }

  @MainActor
  private func shot(_ appearance: String, _ step: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "reply-flow-\(step)-\(appearance)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
