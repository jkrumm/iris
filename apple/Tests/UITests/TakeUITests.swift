import XCTest

/// Record from anywhere: start on History, browse with the banner, come back through it, stop. On fake capture.
final class TakeUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  @MainActor
  func testStartFromHistoryBrowseWithTheBannerReturnAndStop() {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments
    app.launch()
    XCTAssertTrue(element(app, "history.list").waitForExistence(timeout: 10))

    // Start from History: the record control above the tab bar opens the take screen.
    let record = element(app, "record.start")
    XCTAssertTrue(record.waitForExistence(timeout: 10))
    record.tap()
    XCTAssertTrue(element(app, "take.screen").waitForExistence(timeout: 10))
    XCTAssertTrue(element(app, "take.timer").exists)
    XCTAssertFalse(element(app, "take.banner").exists, "the full screen replaces the banner")

    // Browse: minimizing leaves the compact banner, and it follows to another tab.
    element(app, "take.minimize").tap()
    XCTAssertTrue(element(app, "take.banner").waitForExistence(timeout: 10))
    XCTAssertFalse(element(app, "take.screen").exists)
    app.tabBars.buttons["Stats"].tap()
    XCTAssertTrue(element(app, "stats.view").waitForExistence(timeout: 10))
    XCTAssertTrue(element(app, "take.banner").waitForExistence(timeout: 10), "the banner stays on every screen")
    app.tabBars.buttons["History"].tap()

    // Tapping the banner returns to the full take.
    let open = element(app, "take.banner.open")
    XCTAssertTrue(open.waitForExistence(timeout: 10))
    open.tap()
    XCTAssertTrue(element(app, "take.screen").waitForExistence(timeout: 10))

    // Stop: the take ends and sends; neither the screen nor the banner stays.
    element(app, "take.stop").tap()
    let gone = NSPredicate(format: "exists == false")
    expectation(for: gone, evaluatedWith: element(app, "take.screen"))
    expectation(for: gone, evaluatedWith: element(app, "take.banner"))
    waitForExpectations(timeout: 15)
    XCTAssertTrue(element(app, "history.list").exists)
    XCTAssertTrue(element(app, "record.start").waitForExistence(timeout: 10), "the record control is back")
  }

  @MainActor
  func testDiscardingTheTakeLeavesNothingBehind() {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments
    app.launch()
    XCTAssertTrue(element(app, "history.list").waitForExistence(timeout: 10))

    element(app, "record.start").tap()
    XCTAssertTrue(element(app, "take.screen").waitForExistence(timeout: 10))
    element(app, "take.discard").tap()
    let confirm = app.buttons["take.discard.confirm"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 10))
    confirm.tap()

    let gone = NSPredicate(format: "exists == false")
    expectation(for: gone, evaluatedWith: element(app, "take.screen"))
    waitForExpectations(timeout: 15)
    XCTAssertFalse(element(app, "take.banner").exists)
  }
}
