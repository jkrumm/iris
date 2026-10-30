import XCTest

final class StatsSettingsUITests: IrisUITestCase {
  @MainActor
  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments
    start(app)
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["history.list"], timeout: 10))
    return app
  }

  @MainActor
  func testStatsTabDrawsTheChartAndSwitchesToWeeks() {
    let app = launch()
    app.tabBars.buttons["Stats"].tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["stats.chart"], timeout: 10))

    app.segmentedControls["stats.picker"].buttons["Weeks"].tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["stats.chart"], timeout: 5))
  }

  /// The fake server answers, so the row reads Connected (the unreachable and rejected rows are unit-tested on the model).
  @MainActor
  func testTheServerRowReadsConnectedWhenTheFakeServerAnswers() {
    let app = launch()
    app.tabBars.buttons["Settings"].tap()
    let status = app.staticTexts["settings.server.status"]
    XCTAssertTrue(waitForPresence(status))
    let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != 'Checking…'"), object: status)
    _ = XCTWaiter().wait(for: [settled], timeout: 15)
    XCTAssertTrue(status.label.hasSuffix("Connected"), status.label)
    XCTAssertTrue(waitForAbsence(app.descendants(matching: .any)["settings.server.hint"], timeout: 2))
  }

  @MainActor
  func testDiagnosticsCopiesTheMemoIDAndConfirms() {
    let app = launch()
    app.tabBars.buttons["Settings"].tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["settings.outbox.empty"], timeout: 10))

    app.buttons["settings.diagnostics"].tap()
    let copy = app.buttons["diagnostics.copy"]
    XCTAssertTrue(waitForPresence(copy, timeout: 10))
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
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["history.list"], timeout: 10))
    app.tabBars.buttons["Settings"].tap()

    let reset = app.buttons["settings.outbox.reset"]
    XCTAssertTrue(waitForPresence(reset, timeout: 10))
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["settings.outbox.unavailable"], timeout: 2))
    reset.tap()

    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["settings.outbox.empty"], timeout: 10))
    XCTAssertTrue(waitForAbsence(app.buttons["settings.outbox.reset"], timeout: 1))
    XCTAssertTrue(waitForAbsence(app.descendants(matching: .any)["settings.outbox.unavailable"], timeout: 1))

    app.buttons["settings.diagnostics"].tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["diagnostics.quarantined"], timeout: 10))
  }
}

final class ProductionLaunchUITests: IrisUITestCase {
  @MainActor
  func testWithoutTheFakeFlagAndNoConnectionTheAppOpensOnTheConnectionForm() {
    let app = XCUIApplication()
    app.launchArguments = []
    start(app)
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["settings.connection.url"], timeout: 10))
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["settings.connection.token"], timeout: 2))
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["settings.connection.hint"], timeout: 2))
    XCTAssertTrue(waitForAbsence(app.descendants(matching: .any)["history.list"], timeout: 1))

    // History has nothing to load without a connection: it says so and leads back to the form.
    app.tabBars.buttons["History"].tap()
    let connect = app.buttons["history.connect"]
    XCTAssertTrue(waitForPresence(connect, timeout: 10))
    connect.tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["settings.connection.url"], timeout: 10))
  }
}
