import XCTest

final class SmokeUITests: IrisUITestCase {
  @MainActor
  func testHistoryListOpensDetail() {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments
    start(app)

    let list = app.descendants(matching: .any)["history.list"]
    XCTAssertTrue(list.waitForExistence(timeout: 10))

    let firstRow = app.descendants(matching: .any).matching(identifier: "history.row").firstMatch
    XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
    XCTAssertTrue(firstRow.isHittable)

    firstRow.tap()
    XCTAssertTrue(app.descendants(matching: .any)["memo.detail"].waitForExistence(timeout: 10))
  }
}
