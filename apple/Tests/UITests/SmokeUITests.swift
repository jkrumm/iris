import XCTest

final class SmokeUITests: IrisUITestCase {
  @MainActor
  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments
    start(app)

    let list = app.descendants(matching: .any)["history.list"]
    XCTAssertTrue(waitForPresence(list, timeout: 10))
    return app
  }

  /// The newest sample memo is a Hermes memo: every Hermes memo opens as a conversation.
  @MainActor
  func testHistoryListOpensTheConversation() {
    let app = launch()

    let firstRow = app.descendants(matching: .any).matching(identifier: "history.row").firstMatch
    XCTAssertTrue(waitForPresence(firstRow, timeout: 10))
    XCTAssertTrue(firstRow.isHittable)

    firstRow.tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["thread.view"], timeout: 10))
  }

  /// A transcript-only memo keeps the document detail.
  @MainActor
  func testHistoryListOpensTheDetailOfATranscript() {
    let app = launch()

    revealRow(containing: "Nur ein Gedanke", in: app).tap()
    XCTAssertTrue(waitForPresence(app.descendants(matching: .any)["memo.detail"], timeout: 10))
  }
}
