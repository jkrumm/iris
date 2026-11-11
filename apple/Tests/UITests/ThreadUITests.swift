import XCTest

final class ThreadUITests: IrisUITestCase {
  @MainActor
  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    // A slower fake server, so the pending turn can be seen before the answer replaces it: the running turn lasts 85 % of a
    // step (the answer streams in then). At 3 s it was gone 2.55 s after Send, before a test that first finds the sent text
    // (about 2.7 s on the mini) looked for it.
    app.launchArguments = SampleClock.arguments + ["-IrisFakeStepMs", "6000"]
    start(app)
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["history.list"], timeout: 10))
    return app
  }

  @MainActor
  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  /// Scrolls `container` until `element` can be tapped and starts below `top` (the floating bars cover the first 156 pt of
  /// the thread, and `isHittable` does not know about them); bounded, so a missing element fails instead of hanging.
  @MainActor
  private func reveal(_ element: XCUIElement, in container: XCUIElement, up: Bool = true, below top: CGFloat = 0) {
    var attempts = 0
    while !element.isHittable || (top > 0 && element.frame.minY < top), attempts < 8 {
      if up { container.swipeUp() } else { container.swipeDown() }
      attempts += 1
    }
  }

  /// The answer that has not arrived: the pipeline's dashes, or the tool list once the first tool started (the fake starts one
  /// 15 % into its step, which a slow runner can reach before the first query).
  @MainActor
  private func runningTurn(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier IN %@", ["thread.turn.pending", "thread.turn.activity"])).firstMatch
  }

  /// Types `text` into the reply field of the conversation and sends it.
  @MainActor
  private func typeReply(_ text: String, in app: XCUIApplication) {
    let field = element(app, "thread.reply.field")
    XCTAssertTrue(waitForPresence(field, timeout: 10))
    field.tap()
    field.typeText(text)
    let send = app.buttons["thread.reply.send"]
    XCTAssertTrue(waitForPresence(send, timeout: 5))
    send.tap()
  }

  @MainActor
  func testAThreadRowOpensTheThreadAndATypedReplyJoinsIt() {
    let app = launch()
    let row = revealRow(containing: "Hang guards are not retried", in: app)
    row.tap()

    let thread = element(app, "thread.view")
    XCTAssertTrue(waitForPresence(thread, timeout: 10))
    // Both answers are there: the follow-up's text is the last turn, and the first answer holds the rendered diagram.
    XCTAssertTrue(waitForPresence(app.staticTexts["And a hang guard, is that retried too?"], timeout: 10))
    let diagram = element(app, "thread.diagram")
    reveal(diagram, in: thread, up: false, below: 160)
    XCTAssertTrue(waitForPresence(diagram, timeout: 10))

    // The diagram opens full screen and closes again.
    diagram.tap()
    XCTAssertTrue(waitForPresence(element(app, "thread.diagram.zoom"), timeout: 10))
    app.buttons["thread.diagram.close"].tap()
    XCTAssertTrue(waitForPresence(thread, timeout: 10))

    // Reply by text from the bar: the sent text joins the thread with a pending answer, then the answer.
    typeReply("What about the narrow table?", in: app)
    XCTAssertTrue(waitForPresence(app.staticTexts["What about the narrow table?"], timeout: 10))
    let pending = runningTurn(app)
    XCTAssertTrue(waitForPresence(pending, timeout: 10))

    // The fake server answers the typed memo, and the answer replaces the pending turn.
    let answer = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "fake answer to your message")).firstMatch
    XCTAssertTrue(waitForPresence(answer, timeout: 20))
    XCTAssertTrue(waitForAbsence(pending, timeout: 10))
  }

  /// A single finished Hermes memo (its own session, not one of the seeded multi-memo threads) opens the conversation, not the
  /// document detail, and a typed reply appears in place.
  @MainActor
  func testASingleHermesMemoOpensTheConversationAndATypedReplyAppearsInPlace() {
    let app = launch()
    revealRow(containing: "Wochenplan abgestimmt", in: app).tap()

    let thread = element(app, "thread.view")
    XCTAssertTrue(waitForPresence(thread, timeout: 10))
    XCTAssertTrue(waitForAbsence(element(app, "memo.detail"), timeout: 2), "a Hermes memo is a conversation")
    XCTAssertTrue(
      waitForPresence(element(app, "thread.reply.field"), timeout: 10), "the reply bar is there from the first turn")

    typeReply("And the Friday standup?", in: app)
    XCTAssertTrue(waitForPresence(thread.staticTexts["And the Friday standup?"], timeout: 10))
    XCTAssertTrue(waitForPresence(runningTurn(app), timeout: 10))
    XCTAssertTrue(waitForPresence(thread, timeout: 2), "still the same screen")
    XCTAssertTrue(waitForAbsence(element(app, "memo.detail"), timeout: 1))
  }

  /// While the fake `act` runs (3 s), each tool shows as a row of the working list as it starts, before the answer; the answer
  /// then replaces the list.
  @MainActor
  func testTheRunningTurnShowsEachToolAsItStartsBeforeTheAnswer() {
    let app = launch()
    revealRow(containing: "Wochenplan abgestimmt", in: app).tap()
    XCTAssertTrue(waitForPresence(element(app, "thread.view"), timeout: 10))

    typeReply("And the Friday standup?", in: app)
    let activity = element(app, "thread.turn.activity")
    XCTAssertTrue(waitForPresence(activity, timeout: 10))

    let rows = app.descendants(matching: .any).matching(identifier: "thread.turn.activity.row")
    let deadline = Date().addingTimeInterval(10)
    var count = 0
    while count < 2, Date() < deadline {
      count = rows.count
      if count < 2 { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
    }
    XCTAssertGreaterThanOrEqual(count, 2, "the second tool adds a row")

    let answer = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "fake answer to your message")).firstMatch
    XCTAssertTrue(waitForPresence(answer, timeout: 20))
    XCTAssertTrue(waitForAbsence(activity, timeout: 10))
  }

  /// The hold-to-talk control works on the first turn of a conversation too: the take becomes a turn in the same screen.
  @MainActor
  func testAVoiceReplyOnTheFirstTurnJoinsTheSameScreen() {
    let app = launch()
    revealRow(containing: "Wochenplan abgestimmt", in: app).tap()

    let thread = element(app, "thread.view")
    XCTAssertTrue(waitForPresence(thread, timeout: 10))
    let pill = element(app, "thread.reply.voice")
    XCTAssertTrue(waitForPresence(pill, timeout: 10))
    XCTAssertTrue(pill.isEnabled, "the thread id is known after act, so voice is on")
    pill.press(forDuration: 1.5)

    // The fake answers fast on a loaded runner: the answer to the voice memo is what counts, in the same screen.
    let answer = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "fake answer to your voice memo")).firstMatch
    XCTAssertTrue(waitForPresence(answer, timeout: 30))
    XCTAssertTrue(waitForPresence(thread, timeout: 2))
    XCTAssertTrue(waitForAbsence(element(app, "memo.detail"), timeout: 1))
  }

  /// A Hermes memo that failed at act is a conversation too; its Details button opens the sheet with the steps and the retry.
  @MainActor
  func testTheDetailsButtonOpensTheStepsAndRetryOfAFailedMemo() {
    let app = launch()
    revealRow(containing: "xcodegen", in: app).tap()

    XCTAssertTrue(waitForPresence(element(app, "thread.view"), timeout: 10))
    let details = app.buttons["thread.turn.details"].firstMatch
    XCTAssertTrue(waitForPresence(details, timeout: 10))
    details.tap()

    XCTAssertTrue(waitForPresence(element(app, "memo.details"), timeout: 10))
    XCTAssertTrue(waitForPresence(app.staticTexts["Transcribe"], timeout: 10), "a failed memo opens its steps")
    XCTAssertTrue(waitForPresence(app.buttons["detail.step.retry"], timeout: 5))
    XCTAssertTrue(waitForPresence(app.buttons["detail.action.retry"], timeout: 5))
  }
}
