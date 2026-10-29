import XCTest

final class HistorySwipeUITests: IrisUITestCase {
  private let headline = "Wochenplan abgestimmt"

  @MainActor
  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments + ["-IrisUndoSeconds", "60"]
    start(app)
    XCTAssertTrue(app.descendants(matching: .any)["history.list"].waitForExistence(timeout: 10))
    return app
  }

  @MainActor
  private func row(in app: XCUIApplication) -> XCUIElement {
    let predicate = NSPredicate(format: "identifier == 'history.row' AND label CONTAINS %@", headline)
    return app.descendants(matching: .any).matching(predicate).firstMatch
  }

  /// The row's combined element carries the state as its accessibility value; the button around it does not.
  @MainActor
  private func markedDone(in app: XCUIApplication) -> XCUIElement {
    let predicate = NSPredicate(format: "label CONTAINS %@ AND value CONTAINS 'Marked done'", headline)
    return app.descendants(matching: .any).matching(predicate).firstMatch
  }

  @MainActor
  func testSwipeRightMarksTheRowDone() {
    let app = launch()
    let target = row(in: app)
    XCTAssertTrue(target.waitForExistence(timeout: 10))
    target.scrollIntoClearBand(of: app.descendants(matching: .any)["history.list"], app: app)
    XCTAssertFalse(markedDone(in: app).exists)

    // Dragging past the full-swipe threshold fires the first action; `swipeRight()` can stop short of it.
    let start = target.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
    let end = target.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
    start.press(forDuration: 0.1, thenDragTo: end)

    XCTAssertTrue(markedDone(in: app).waitForExistence(timeout: 10))
  }

  @MainActor
  func testDeleteRemovesTheRowAndUndoBringsItBack() {
    let app = launch()
    let target = row(in: app)
    XCTAssertTrue(target.waitForExistence(timeout: 10))
    target.scrollIntoClearBand(of: app.descendants(matching: .any)["history.list"], app: app)

    // A short drag reveals the buttons; a full swipe would archive instead.
    let start = target.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
    let end = target.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
    start.press(forDuration: 0.1, thenDragTo: end)
    let delete = app.buttons["history.swipe.delete"]
    XCTAssertTrue(delete.waitForExistence(timeout: 5))
    delete.tap()

    XCTAssertTrue(app.descendants(matching: .any)["history.toast"].waitForExistence(timeout: 5))
    XCTAssertFalse(row(in: app).waitForExistence(timeout: 1))

    let undo = app.buttons["Undo"]
    XCTAssertTrue(undo.waitForExistence(timeout: 5))
    undo.tap()
    XCTAssertTrue(row(in: app).waitForExistence(timeout: 10))
  }
}
