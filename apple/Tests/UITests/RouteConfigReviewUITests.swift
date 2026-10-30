import XCTest

/// The route configuration render of Wave 17 I6, walked once per appearance with a screenshot at every screen, for the
/// owner's async review (docs/design/README.md). The surface is review-only: Settings shows its "Routes" row only under
/// `-IrisRouteConfigReview`. Export the PNGs with `scripts/route-config-shots.sh`.
final class RouteConfigReviewUITests: IrisUITestCase {
  /// The appearance outlives the test on the simulator, and every UI test class that runs after this one expects light.
  override func tearDown() {
    // The app ends first: switching appearance under a running app is what the next launch would have to terminate.
    super.tearDown()
    MainActor.assumeIsolated { XCUIDevice.shared.appearance = .light }
  }

  @MainActor
  func testRoutesLight() {
    walk(appearance: .light, name: "light")
  }

  @MainActor
  func testRoutesDark() {
    walk(appearance: .dark, name: "dark")
  }

  @MainActor
  private func walk(appearance: XCUIDevice.Appearance, name: String) {
    XCUIDevice.shared.appearance = appearance
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments + ["-IrisRouteConfigReview"]
    start(app)

    app.tabBars.buttons["Settings"].tap()
    let row = app.buttons["settings.routes"]
    var scrolls = 0
    while !row.isHittable, scrolls < 6 {
      app.swipeUp()
      scrolls += 1
    }
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.tap()

    // 1: the overview, journal not set up on this server.
    XCTAssertTrue(app.descendants(matching: .any)["routes.view"].waitForExistence(timeout: 10))
    shot(name, "1-overview")

    // 2: herdr, with the live tabs.
    let herdr = app.buttons["routes.destination.herdr"]
    XCTAssertTrue(herdr.waitForExistence(timeout: 5))
    herdr.tap()
    XCTAssertTrue(app.descendants(matching: .any)["routes.destination.view"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["iris · w16"].exists)
    shot(name, "2-herdr")
    app.navigationBars.buttons.firstMatch.tap()

    // 3: a destination the server has not set up.
    let journal = app.buttons["routes.destination.journal"]
    XCTAssertTrue(journal.waitForExistence(timeout: 5))
    journal.tap()
    XCTAssertTrue(app.descendants(matching: .any)["routes.destination.unavailable"].waitForExistence(timeout: 10))
    shot(name, "3-journal")
    app.navigationBars.buttons.firstMatch.tap()

    // 4: the microphone per audio route.
    let audio = app.buttons["routes.audio"]
    XCTAssertTrue(audio.waitForExistence(timeout: 5))
    audio.tap()
    XCTAssertTrue(app.descendants(matching: .any)["routes.audio.view"].waitForExistence(timeout: 10))
    shot(name, "4-audio")
  }

  @MainActor
  private func shot(_ appearance: String, _ step: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "route-config-\(step)-\(appearance)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
