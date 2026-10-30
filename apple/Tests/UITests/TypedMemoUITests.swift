import XCTest

final class TypedMemoUITests: IrisUITestCase {
  @MainActor
  func testSendingATypedMemoShowsItInHistory() {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments
    start(app)
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["history.list"], timeout: 10))

    app.buttons["history.compose"].tap()
    let send = app.buttons["composer.send"]
    XCTAssertTrue(waitForPresence(send, timeout: 5))
    XCTAssertFalse(send.isEnabled, "nothing typed yet")

    app.buttons["Chat"].tap()
    let field = app.textViews["composer.field"]
    XCTAssertTrue(waitForPresence(field, timeout: 5))
    field.tap()
    field.typeText("Order a router and check the network plan")
    XCTAssertTrue(send.isEnabled)
    send.tap()

    // The sheet closes and the new memo is the top row of History.
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["history.list"], timeout: 10))
    let row = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == 'history.row' AND label CONTAINS %@", "Order a router")).firstMatch
    XCTAssertTrue(waitForPresence(row, timeout: 10))
    XCTAssertTrue(waitForAbsence(app.buttons["composer.send"], timeout: 1))
  }
}
