import XCTest

final class StatsSettingsUITests: XCTestCase {
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

  @MainActor
  func testStatsTabDrawsTheChartAndSwitchesToWeeks() {
    let app = launch()
    app.tabBars.buttons["Stats"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["stats.chart"].waitForExistence(timeout: 10))

    app.segmentedControls["stats.picker"].buttons["Weeks"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["stats.chart"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testDiagnosticsCopiesTheMemoIDAndConfirms() {
    let app = launch()
    app.tabBars.buttons["Settings"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["settings.outbox.empty"].waitForExistence(timeout: 10))

    app.buttons["settings.diagnostics"].tap()
    let copy = app.buttons["diagnostics.copy"]
    XCTAssertTrue(copy.waitForExistence(timeout: 10))
    XCTAssertEqual(copy.label, "Copy memo id")
    copy.tap()
    XCTAssertEqual(app.buttons["diagnostics.copy"].label, "Copied")
  }
}

final class ProductionLaunchUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testWithoutTheFakeFlagAndNoConnectionTheAppOpensOnTheConnectionForm() {
    let app = XCUIApplication()
    app.launchArguments = []
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["settings.connection.url"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.descendants(matching: .any)["settings.connection.token"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["settings.connection.hint"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["history.list"].exists)
  }
}
