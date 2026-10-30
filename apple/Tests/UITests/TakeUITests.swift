import XCTest

/// Record from anywhere: start on History, browse with the banner, come back through it, stop. On fake capture.
final class TakeUITests: IrisUITestCase {
  @MainActor
  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  @MainActor
  func testStartFromHistoryBrowseWithTheBannerReturnAndStop() {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments
    start(app)
    XCTAssertTrue(waitForPresence(element(app, "history.list"), timeout: 10))

    // Start from History: the record control above the tab bar opens the take screen.
    let record = element(app, "record.start")
    XCTAssertTrue(waitForPresence(record, timeout: 10))
    record.tap()
    XCTAssertTrue(waitForPresence(element(app, "take.screen"), timeout: 10))
    XCTAssertTrue(waitForPresence(element(app, "take.timer"), timeout: 2))
    XCTAssertTrue(waitForAbsence(element(app, "take.banner"), timeout: 1), "the full screen replaces the banner")

    // Browse: minimizing leaves the compact banner, and it follows to another tab.
    element(app, "take.minimize").tap()
    XCTAssertTrue(waitForPresence(element(app, "take.banner"), timeout: 10))
    XCTAssertTrue(waitForAbsence(element(app, "take.screen"), timeout: 1))
    app.tabBars.buttons["Stats"].tap()
    XCTAssertTrue(waitForPresence(element(app, "stats.view"), timeout: 10))
    XCTAssertTrue(waitForPresence(element(app, "take.banner"), timeout: 10), "the banner stays on every screen")
    app.tabBars.buttons["History"].tap()

    // Tapping the banner returns to the full take.
    let open = element(app, "take.banner.open")
    XCTAssertTrue(waitForPresence(open, timeout: 10))
    open.tap()
    XCTAssertTrue(waitForPresence(element(app, "take.screen"), timeout: 10))

    // Stop: the take ends and sends; neither the screen nor the banner stays.
    element(app, "take.stop").tap()
    let gone = NSPredicate(format: "exists == false")
    expectation(for: gone, evaluatedWith: element(app, "take.screen"))
    expectation(for: gone, evaluatedWith: element(app, "take.banner"))
    waitForExpectations(timeout: 15)
    XCTAssertTrue(waitForPresence(element(app, "history.list"), timeout: 2))
    XCTAssertTrue(waitForPresence(element(app, "record.start"), timeout: 10), "the record control is back")
  }

  @MainActor
  func testDiscardingTheTakeLeavesNothingBehind() {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments
    start(app)
    XCTAssertTrue(waitForPresence(element(app, "history.list"), timeout: 10))

    element(app, "record.start").tap()
    XCTAssertTrue(waitForPresence(element(app, "take.screen"), timeout: 10))
    element(app, "take.discard").tap()
    let confirm = app.buttons["take.discard.confirm"].firstMatch
    XCTAssertTrue(waitForPresence(confirm, timeout: 10))
    confirm.tap()

    let gone = NSPredicate(format: "exists == false")
    expectation(for: gone, evaluatedWith: element(app, "take.screen"))
    waitForExpectations(timeout: 15)
    XCTAssertTrue(waitForAbsence(element(app, "take.banner"), timeout: 1))
  }
}
