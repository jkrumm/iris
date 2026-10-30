import XCTest

final class ThreadUITests: IrisUITestCase {
  @MainActor
  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    // A slower fake server, so the pending turn can be seen before the answer replaces it.
    app.launchArguments = SampleClock.arguments + ["-IrisFakeStepMs", "3000"]
    start(app)
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["history.list"], timeout: 10))
    return app
  }

  /// Scrolls `list` until `row` can be tapped; bounded, so a missing row fails instead of hanging.
  @MainActor
  private func reveal(_ element: XCUIElement, in container: XCUIElement, up: Bool = true) {
    var attempts = 0
    while !element.isHittable, attempts < 8 {
      if up { container.swipeUp() } else { container.swipeDown() }
      attempts += 1
    }
  }

  @MainActor
  func testAChatRowOpensTheThreadAndATypedReplyJoinsIt() {
    let app = launch()
    let row = revealRow(containing: "How the step runner retries", in: app)
    row.tap()

    let thread = app.descendants(matching: .any)["thread.view"]
    XCTAssertTrue(waitForPresence(thread, timeout: 10))
    // Both answers are there: the follow-up's text is the last turn, and the first answer holds the rendered diagram.
    XCTAssertTrue(waitForPresence(app.staticTexts["And a hang guard, is that retried too?"], timeout: 10))
    let diagram = app.descendants(matching: .any)["thread.diagram"]
    reveal(diagram, in: thread, up: false)
    XCTAssertTrue(waitForPresence(diagram, timeout: 10))

    // The diagram opens full screen and closes again.
    diagram.tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["thread.diagram.zoom"], timeout: 10))
    app.buttons["thread.diagram.close"].tap()
    XCTAssertTrue(waitForPresence(thread, timeout: 10))

    // Reply by text: the composer is bound to the thread (no mode chips), the sent text joins the thread with a pending answer, then the answer.
    app.buttons["thread.reply.text"].tap()
    let field = app.textViews["composer.field"]
    XCTAssertTrue(waitForPresence(field, timeout: 5))
    XCTAssertTrue(waitForAbsence(app.descendants(matching: .any)["composer.modes"], timeout: 1))
    field.tap()
    field.typeText("What about the narrow table?")
    app.buttons["composer.send"].tap()

    XCTAssertTrue(waitForPresence(app.staticTexts["What about the narrow table?"], timeout: 10))
    let pending = app.descendants(matching: .any)["thread.turn.pending"]
    XCTAssertTrue(waitForPresence(pending, timeout: 10))
    XCTAssertTrue(waitForAbsence(app.buttons["composer.send"], timeout: 1))

    // The fake server answers the typed memo, and the answer replaces the pending turn.
    let answer = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", "fake answer to your message")).firstMatch
    XCTAssertTrue(waitForPresence(answer, timeout: 20))
    XCTAssertTrue(waitForAbsence(pending, timeout: 10))
  }
}
