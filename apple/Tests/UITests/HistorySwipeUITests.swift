import XCTest

final class HistorySwipeUITests: IrisUITestCase {
  private let headline = "Wochenplan abgestimmt"

  @MainActor
  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    // A hosted runner spent over 80 s on the absence checks below (Wave 19): 60 s let the toast expire before Undo.
    app.launchArguments = SampleClock.arguments + ["-IrisUndoSeconds", "600"]
    start(app)
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["history.list"], timeout: 10))
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

  /// Drags across `target` from `fromX` to `toX` (fractions of its width). The row's frame is read once, through the retrying
  /// query, and the drag runs on screen coordinates: a drag on the row's own coordinate asks the app for the row again, and
  /// on a loaded runner that query timed out three times in a row (run 41614503885, 287 s) and failed the test.
  @MainActor
  private func drag(_ target: XCUIElement, in app: XCUIApplication, fromX: Double, toX: Double) {
    var frame: CGRect?
    for _ in 0..<3 where frame == nil {
      frame = QueryRetry.attempt({ target.frame }) ?? nil
    }
    guard let frame else { return XCTFail("could not read the row's frame") }
    let origin = app.coordinate(withNormalizedOffset: .zero)
    let start = origin.withOffset(CGVector(dx: frame.minX + frame.width * fromX, dy: frame.midY))
    let end = origin.withOffset(CGVector(dx: frame.minX + frame.width * toX, dy: frame.midY))
    for _ in 0..<3 {
      if QueryRetry.attempt({ start.press(forDuration: 0.1, thenDragTo: end) }) != nil { return }
    }
    XCTFail("the drag never ran: the app did not answer its queries")
  }

  @MainActor
  func testSwipeRightMarksTheRowDone() {
    let app = launch()
    let target = row(in: app)
    XCTAssertTrue(waitForPresence(target, timeout: 10))
    target.scrollIntoClearBand(of: app.descendants(matching: .any)["history.list"], app: app)
    XCTAssertTrue(waitForAbsence(markedDone(in: app), timeout: 1))

    // Dragging past the full-swipe threshold fires the first action; `swipeRight()` can stop short of it.
    drag(target, in: app, fromX: 0.1, toX: 0.98)

    XCTAssertTrue(waitForPresence(markedDone(in: app), timeout: 10))
  }

  @MainActor
  func testDeleteRemovesTheRowAndUndoBringsItBack() {
    let app = launch()
    let target = row(in: app)
    XCTAssertTrue(waitForPresence(target, timeout: 10))
    target.scrollIntoClearBand(of: app.descendants(matching: .any)["history.list"], app: app)

    // A short drag reveals the buttons; a full swipe would archive instead.
    drag(target, in: app, fromX: 0.9, toX: 0.55)
    let delete = app.buttons["history.swipe.delete"]
    XCTAssertTrue(waitForPresence(delete, timeout: 5))
    delete.tap()

    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["history.toast"], timeout: 5))
    let undo = app.buttons["Undo"]
    XCTAssertTrue(waitForPresence(undo, timeout: 5))
    XCTAssertTrue(waitForAbsence(row(in: app), timeout: 5))
    XCTAssertTrue(staysAbsent(row(in: app), for: 1), "the deleted row came back before Undo")

    undo.tap()
    XCTAssertTrue(waitForPresence(row(in: app), timeout: 10))
  }
}
