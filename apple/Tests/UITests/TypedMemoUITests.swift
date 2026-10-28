import XCTest

final class TypedMemoUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func testSendingATypedMemoShowsItInHistory() {
    let app = XCUIApplication()
    app.launchArguments = ["-IrisFakeCapture"]
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["history.list"].waitForExistence(timeout: 10))

    app.buttons["history.compose"].tap()
    let send = app.buttons["composer.send"]
    XCTAssertTrue(send.waitForExistence(timeout: 5))
    XCTAssertFalse(send.isEnabled, "nothing typed yet")

    app.buttons["Chat"].tap()
    let field = app.textViews["composer.field"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText("Order a router and check the network plan")
    XCTAssertTrue(send.isEnabled)
    send.tap()

    // The sheet closes and the new memo is the top row of History.
    XCTAssertTrue(app.descendants(matching: .any)["history.list"].waitForExistence(timeout: 10))
    let row = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == 'history.row' AND label CONTAINS %@", "Order a router")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["composer.send"].exists)
  }
}
