import XCTest

final class StatsSettingsUITests: IrisUITestCase {
  @MainActor
  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments
    start(app)
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

/// A saved outbox that cannot be decoded (`-IrisFakeUnreadableOutbox`): Settings offers a reset that sets the file aside.
final class OutboxResetUITests: IrisUITestCase {
  @MainActor
  func testAnUnreadableOutboxCanBeResetAndTheSetAsideFileIsShareable() {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments + ["-IrisFakeUnreadableOutbox"]
    start(app)
    XCTAssertTrue(app.descendants(matching: .any)["history.list"].waitForExistence(timeout: 10))
    app.tabBars.buttons["Settings"].tap()

    let reset = app.buttons["settings.outbox.reset"]
    XCTAssertTrue(reset.waitForExistence(timeout: 10))
    XCTAssertTrue(app.descendants(matching: .any)["settings.outbox.unavailable"].exists)
    reset.tap()

    XCTAssertTrue(app.descendants(matching: .any)["settings.outbox.empty"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["settings.outbox.reset"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["settings.outbox.unavailable"].exists)

    app.buttons["settings.diagnostics"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["diagnostics.quarantined"].waitForExistence(timeout: 10))
  }
}

final class ProductionLaunchUITests: IrisUITestCase {
  @MainActor
  func testWithoutTheFakeFlagAndNoConnectionTheAppOpensOnTheConnectionForm() {
    let app = XCUIApplication()
    app.launchArguments = []
    start(app)
    XCTAssertTrue(app.descendants(matching: .any)["settings.connection.url"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.descendants(matching: .any)["settings.connection.token"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["settings.connection.hint"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["history.list"].exists)

    // History has nothing to load without a connection: it says so and leads back to the form.
    app.tabBars.buttons["History"].tap()
    let connect = app.buttons["history.connect"]
    XCTAssertTrue(connect.waitForExistence(timeout: 10))
    connect.tap()
    XCTAssertTrue(app.descendants(matching: .any)["settings.connection.url"].waitForExistence(timeout: 10))
  }
}
