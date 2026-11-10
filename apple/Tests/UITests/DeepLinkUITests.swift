import XCTest

final class DeepLinkUITests: IrisUITestCase {
  private let chatThreadID = "c1a0b7d2-4e61-4f38-9a15-3d8e6b2f7c40"

  @MainActor
  func testAConversationLinkOpensTheThread() {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments + ["-IrisOpenURL", "iris://memo/\(chatThreadID)"]
    start(app)
    let thread = app.descendants(matching: .any)["thread.view"]
    XCTAssertTrue(waitForPresence(thread, timeout: 15))
    XCTAssertTrue(waitForPresence(app.staticTexts["And a hang guard, is that retried too?"], timeout: 10))
  }

  @MainActor
  func testAKeyboardLinkFocusesTheReplyField() {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments + ["-IrisOpenURL", "iris://memo/\(chatThreadID)?focus=keyboard"]
    start(app)
    let field = app.descendants(matching: .any)["thread.reply.field"]
    XCTAssertTrue(waitForPresence(field, timeout: 15))
    XCTAssertTrue(waitForPresence(app.keyboards.firstMatch, timeout: 10))
  }
}
