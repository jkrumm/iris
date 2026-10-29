import XCTest

final class ThreadUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["history.list"].waitForExistence(timeout: 10))
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
    let row = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == 'history.row' AND label CONTAINS %@", "How the step runner retries"))
      .firstMatch
    // The oldest rows are not in the tree until the list has scrolled to them.
    let list = app.descendants(matching: .any)["history.list"]
    var scrolls = 0
    while !row.exists, scrolls < 8 {
      list.swipeUp()
      scrolls += 1
    }
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.scrollIntoClearBand(of: list, app: app)
    row.tap()

    let thread = app.descendants(matching: .any)["thread.view"]
    XCTAssertTrue(thread.waitForExistence(timeout: 10))
    // Both answers are there: the follow-up's text is the last turn, and the first answer holds the rendered diagram.
    XCTAssertTrue(app.staticTexts["And a hang guard, is that retried too?"].waitForExistence(timeout: 10))
    let diagram = app.descendants(matching: .any)["thread.diagram"]
    reveal(diagram, in: thread, up: false)
    XCTAssertTrue(diagram.waitForExistence(timeout: 10))

    // The diagram opens full screen and closes again.
    diagram.tap()
    XCTAssertTrue(app.descendants(matching: .any)["thread.diagram.zoom"].waitForExistence(timeout: 10))
    app.buttons["thread.diagram.close"].tap()
    XCTAssertTrue(thread.waitForExistence(timeout: 10))

    // Reply by text: the composer is bound to the thread (no mode chips), the sent text joins the thread with a pending answer.
    app.buttons["thread.reply.text"].tap()
    let field = app.textViews["composer.field"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    XCTAssertFalse(app.descendants(matching: .any)["composer.modes"].exists)
    field.tap()
    field.typeText("What about the narrow table?")
    app.buttons["composer.send"].tap()

    XCTAssertTrue(app.staticTexts["What about the narrow table?"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.descendants(matching: .any)["thread.turn.pending"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["composer.send"].exists)
  }
}
