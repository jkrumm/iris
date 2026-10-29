import XCTest

/// R2 routing on the fake stack: answer a parked memo, send it to a herdr tab, correct a finished memo's route, record in a
/// chosen mode, play a reply, and the Settings that go with them.
final class RoutingUITests: IrisUITestCase {
  @MainActor
  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments
    start(app)
    XCTAssertTrue(element(app, "history.list").waitForExistence(timeout: 10))
    return app
  }

  @MainActor
  private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  @MainActor
  private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 15) {
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
    waitForExpectations(timeout: timeout)
  }

  @MainActor
  private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 15) {
    expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: element)
    waitForExpectations(timeout: timeout)
  }

  /// Taps `target` until `result` shows up. A tap on a loaded simulator now and then lands while the list is still settling
  /// under the glass bars and does nothing; the retry is only made while the result is absent, so it never acts twice.
  @MainActor
  private func tap(_ target: XCUIElement, until result: XCUIElement) {
    for _ in 0..<3 {
      target.tap()
      if result.waitForExistence(timeout: 5) { return }
    }
    XCTAssertTrue(
      result.waitForExistence(timeout: 10), "tapping \(target.identifier) did not open \(result.identifier)")
  }

  /// Opens the History row whose label contains `text` (the list is lazy: scrolled to until the row is in the tree).
  @MainActor
  private func openRow(containing text: String, in app: XCUIApplication) {
    let row = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == 'history.row' AND label CONTAINS %@", text)).firstMatch
    let list = element(app, "history.list")
    var scrolls = 0
    while !row.exists, scrolls < 8 {
      list.swipeUp()
      scrolls += 1
    }
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.scrollIntoClearBand(of: list, app: app)
    tap(row, until: element(app, "memo.detail"))
  }

  /// Settings is a lazy list: swipes up until `target` is on screen.
  @MainActor
  private func scrollSettings(to target: XCUIElement, in app: XCUIApplication) {
    var swipes = 0
    while !target.isHittable, swipes < 6 {
      element(app, "settings.view").swipeUp()
      swipes += 1
    }
    XCTAssertTrue(target.waitForExistence(timeout: 5))
  }

  /// Ends the take that is running by discarding it. A test that leaves a take recording when the app is terminated leaves the
  /// simulator unsettled for the next launch (the next test then misses its taps).
  @MainActor
  private func discardTake(in app: XCUIApplication) {
    element(app, "take.discard").tap()
    let confirm = app.buttons["take.discard.confirm"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 10))
    confirm.tap()
    waitUntilGone(element(app, "take.screen"))
  }

  /// The pinned needs-route row of the sample data.
  @MainActor
  private func pinnedRow(in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier == 'history.row' AND label CONTAINS %@", "Schreib das bitte"))
      .firstMatch
  }

  /// Opens the route sheet from the pinned row's swipe action: a short drag reveals the buttons (a full swipe would fire the
  /// first one, which is the same, but the tap is the more honest path).
  @MainActor
  private func openRouteSheetFromThePinnedRow(in app: XCUIApplication) {
    let row = pinnedRow(in: app)
    XCTAssertTrue(row.waitForExistence(timeout: 10), "the pinned row is listed")
    row.scrollIntoClearBand(of: element(app, "history.list"), app: app)
    let route = app.buttons["history.swipe.route"]
    for _ in 0..<3 where !route.exists {
      let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
      let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
      start.press(forDuration: 0.1, thenDragTo: end)
      _ = route.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(route.exists, "a pinned needs-route row swipes to a Route action")
    tap(route, until: element(app, "route.sheet"))
  }

  // MARK: Needs route

  @MainActor
  func testAnswerAPinnedNeedsRouteMemoFromHistory() {
    let app = launch()
    openRouteSheetFromThePinnedRow(in: app)

    XCTAssertTrue(element(app, "route.sheet").waitForExistence(timeout: 10))
    XCTAssertTrue(element(app, "route.reason").exists, "the park reason is shown")
    XCTAssertTrue(element(app, "route.suggestion").exists, "the decision model's guess is shown")
    let send = app.buttons["route.submit"]
    XCTAssertTrue(send.isEnabled, "the suggestion is preselected")
    send.tap()

    waitUntilGone(element(app, "route.sheet"))
    // Routed: the row is no longer parked.
    expectation(
      for: NSPredicate(format: "NOT (label CONTAINS 'Needs route')"), evaluatedWith: pinnedRow(in: app))
    waitForExpectations(timeout: 15)
  }

  @MainActor
  func testHerdrWaitsForATab() {
    let app = launch()
    openRouteSheetFromThePinnedRow(in: app)

    app.buttons["Tabs"].tap()
    let tabs = app.buttons.matching(identifier: "route.tab")
    XCTAssertTrue(tabs.firstMatch.waitForExistence(timeout: 10))
    XCTAssertEqual(tabs.count, 2)
    XCTAssertFalse(app.buttons["route.submit"].isEnabled, "herdr needs a tab")

    tabs.element(boundBy: 1).tap()
    let send = app.buttons["route.submit"]
    XCTAssertTrue(send.isEnabled)
    send.tap()
    waitUntilGone(element(app, "route.sheet"))
  }

  @MainActor
  func testAnswerAParkedMemoFromItsDetail() {
    let app = launch()
    openRow(containing: "Schreib das bitte", in: app)

    XCTAssertTrue(element(app, "detail.route.reason").waitForExistence(timeout: 10))
    app.buttons["detail.route.answer"].tap()
    XCTAssertTrue(element(app, "route.sheet").waitForExistence(timeout: 10))
    app.buttons["route.submit"].tap()

    waitUntilGone(element(app, "route.sheet"))
    waitUntilGone(element(app, "detail.route.reason"))
  }

  @MainActor
  func testCorrectAFinishedMemosRoute() {
    let app = launch()
    openRow(containing: "Wochenplan abgestimmt", in: app)

    let wrong = app.buttons["detail.route.correct"]
    XCTAssertTrue(wrong.waitForExistence(timeout: 10))
    wrong.tap()
    XCTAssertTrue(element(app, "route.sheet").waitForExistence(timeout: 10))
    XCTAssertTrue(element(app, "route.note").exists, "a correction says it is only logged")
    XCTAssertFalse(element(app, "route.reason").exists)

    app.buttons["Journal"].tap()
    let log = app.buttons["route.submit"]
    XCTAssertEqual(log.label, "Log correction")
    log.tap()

    waitUntilGone(element(app, "route.sheet"))
    XCTAssertTrue(element(app, "memo.detail").exists, "the memo stays as it was")
    XCTAssertTrue(app.buttons["detail.route.correct"].exists)
  }

  // MARK: Play and the mode picker

  @MainActor
  func testPlayTheReplyFromTheDetail() {
    let app = launch()
    openRow(containing: "Wochenplan abgestimmt", in: app)

    let play = app.buttons["detail.action.play"]
    XCTAssertTrue(play.waitForExistence(timeout: 10))
    XCTAssertEqual(play.label, "Play reply")
    play.tap()
    waitForLabel(app.buttons["detail.action.play"], "Stop reply")
    app.buttons["detail.action.play"].tap()
    waitForLabel(app.buttons["detail.action.play"], "Play reply")
  }

  @MainActor
  func testLongPressOnRecordPicksTheModeIncludingChat() {
    let app = launch()
    let record = element(app, "record.start")
    XCTAssertTrue(record.waitForExistence(timeout: 10))
    record.press(forDuration: 1.2)
    let choose = app.buttons["record.chooseMode"]
    XCTAssertTrue(choose.waitForExistence(timeout: 10), "the long press offers the modes and Choose mode…")
    choose.tap()

    XCTAssertTrue(element(app, "record.modeSheet").waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Chat"].exists, "Chat is a mode of a voice take")
    XCTAssertFalse(app.buttons["Tab"].exists, "a spoken take names its tab while speaking")
    app.buttons["Chat"].tap()
    XCTAssertTrue(element(app, "record.mode.summary").label.contains("conversation"))
    app.buttons["record.mode.start"].tap()

    XCTAssertTrue(element(app, "take.screen").waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Chat"].exists, "the take records in the chosen mode")
    discardTake(in: app)
  }

  // MARK: Settings

  @MainActor
  func testAMicRuleForTheRouteIsAppliedWhenATakeStarts() {
    let app = launch()
    app.tabBars.buttons["Settings"].tap()
    let headset = app.buttons.matching(identifier: "settings.mic.choice").matching(
      NSPredicate(format: "label CONTAINS %@", "Fake Headset")
    ).firstMatch
    XCTAssertTrue(headset.waitForExistence(timeout: 10))
    scrollSettings(to: headset, in: app)
    headset.tap()
    XCTAssertTrue(headset.isSelected, "the chosen input is checked")

    app.tabBars.buttons["History"].tap()
    element(app, "record.start").tap()
    XCTAssertTrue(element(app, "take.screen").waitForExistence(timeout: 10))
    XCTAssertEqual(element(app, "take.microphone").value as? String, "Fake Headset", "the rule picked the input")
    discardTake(in: app)
  }

  @MainActor
  func testSpokenRepliesIsAToggleInSettings() {
    let app = launch()
    app.tabBars.buttons["Settings"].tap()
    let toggle = app.switches["settings.spokenReplies"]
    XCTAssertTrue(toggle.waitForExistence(timeout: 10))
    scrollSettings(to: toggle, in: app)
    XCTAssertEqual(toggle.value as? String, "0")
    // The switch sits at the row's trailing edge; a tap in the middle of the row would hit its label.
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    XCTAssertEqual(app.switches["settings.spokenReplies"].value as? String, "1")
  }
}
