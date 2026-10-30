import XCTest

final class SmokeUITests: IrisUITestCase {
  @MainActor
  func testHistoryListOpensDetail() {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments
    start(app)

    let list = app.descendants(matching: .any)["history.list"]
    XCTAssertTrue(waitForPresence(list, timeout: 10))

    let firstRow = app.descendants(matching: .any).matching(identifier: "history.row").firstMatch
    XCTAssertTrue(waitForPresence(firstRow, timeout: 10))
    XCTAssertTrue(firstRow.isHittable)

    firstRow.tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["memo.detail"], timeout: 10))
  }
}
