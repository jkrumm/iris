import XCTest

/// The two modes on the fake stack: the record row's Hermes button starts a Hermes take, its Transcribe button a Transcribe
/// take and its Text button opens the composer, which sends to Hermes or as a transcript; a memo's detail shows what Hermes made of it; play a reply, and the Settings that go with them.
final class ModesUITests: IrisUITestCase {
  @MainActor
  private func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = SampleClock.arguments
    start(app)
    XCTAssertTrue(waitForPresence(element(app, "history.list"), timeout: 10))
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
      if waitForPresence(result, timeout: 5) { return }
    }
    XCTAssertTrue(
      waitForPresence(result, timeout: 10), "tapping \(target.identifier) did not open \(result.identifier)")
  }

  /// Opens the History row whose label contains `text` (the list is lazy: scrolled to until the row is in the tree).
  @MainActor
  private func openRow(containing text: String, in app: XCUIApplication) {
    let row = revealRow(containing: text, in: app)
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
    XCTAssertTrue(waitForPresence(target, timeout: 5))
  }

  /// Ends the take that is running by discarding it. A test that leaves a take recording when the app is terminated leaves the
  /// simulator unsettled for the next launch (the next test then misses its taps).
  @MainActor
  private func discardTake(in app: XCUIApplication) {
    element(app, "take.discard").tap()
    let confirm = app.buttons["take.discard.confirm"].firstMatch
    XCTAssertTrue(waitForPresence(confirm, timeout: 10))
    confirm.tap()
    waitUntilGone(element(app, "take.screen"))
  }

  // MARK: Play and the record row

  @MainActor
  func testPlayTheReplyFromTheDetail() {
    let app = launch()
    openRow(containing: "Wochenplan abgestimmt", in: app)

    let play = app.buttons["detail.action.play"]
    XCTAssertTrue(waitForPresence(play, timeout: 10))
    XCTAssertEqual(play.label, "Play reply")
    play.tap()
    waitForLabel(app.buttons["detail.action.play"], "Stop reply")
    app.buttons["detail.action.play"].tap()
    waitForLabel(app.buttons["detail.action.play"], "Play reply")
  }

  @MainActor
  func testHermesButtonStartsAHermesTake() {
    let app = launch()
    let record = element(app, "record.start")
    XCTAssertTrue(waitForPresence(record, timeout: 10))
    record.tap()

    XCTAssertTrue(waitForPresence(element(app, "take.screen"), timeout: 10))
    XCTAssertTrue(waitForPresence(app.staticTexts["Hermes"], timeout: 2), "the big button records for Hermes")
    discardTake(in: app)
  }

  @MainActor
  func testTranscribeButtonStartsATranscribeTake() {
    let app = launch()
    let record = element(app, "record.transcribe")
    XCTAssertTrue(waitForPresence(record, timeout: 10))
    record.tap()

    XCTAssertTrue(waitForPresence(element(app, "take.screen"), timeout: 10))
    XCTAssertTrue(waitForPresence(app.staticTexts["Transcribe"], timeout: 2), "the second button records a transcript")
    discardTake(in: app)
  }

  @MainActor
  func testTextButtonOpensTheComposerWithTwoSendTargets() {
    let app = launch()
    let text = element(app, "record.text")
    XCTAssertTrue(waitForPresence(text, timeout: 10))
    text.tap()

    let hermes = app.buttons["composer.send"]
    XCTAssertTrue(waitForPresence(hermes, timeout: 10))
    XCTAssertEqual(hermes.label, "Send to Hermes")
    XCTAssertTrue(waitForPresence(app.buttons["composer.send.transcribe"], timeout: 2))
    XCTAssertFalse(hermes.isEnabled, "nothing typed yet")
    // The retired modes are no target any more.
    for gone in ["Auto", "Journal", "Tab"] {
      XCTAssertTrue(waitForAbsence(app.buttons[gone], timeout: 1), "\(gone) is no mode any more")
    }
  }

  // MARK: Detail

  @MainActor
  func testTheDetailShowsTheKindChipAndWhatHermesUsed() {
    let app = launch()
    openRow(containing: "Mach ein GitHub-Issue", in: app)

    let chip = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@", "Kind: Github issue")).firstMatch
    XCTAssertTrue(waitForPresence(chip, timeout: 10), "the free-form kind is the chip, capitalised")
    let actions = element(app, "detail.actions")
    XCTAssertTrue(waitForPresence(actions, timeout: 2))
    XCTAssertEqual(actions.label, "Hermes used: terminal, github")
  }

  @MainActor
  func testAnswerWithoutToolsHasNoActionsLine() {
    let app = launch()
    openRow(containing: "Wie viele Segmente", in: app)
    XCTAssertTrue(
      waitForPresence(
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Kind: Answer")).firstMatch,
        timeout: 10))
    XCTAssertTrue(waitForAbsence(element(app, "detail.actions"), timeout: 1))
  }

  @MainActor
  func testATranscriptMemoReadsAsTranscript() {
    let app = launch()
    openRow(containing: "Nur ein Gedanke", in: app)
    let chip = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Kind: Transcript"))
      .firstMatch
    XCTAssertTrue(waitForPresence(chip, timeout: 10))
    XCTAssertTrue(waitForAbsence(element(app, "detail.actions"), timeout: 1))
  }

  // MARK: Settings

  @MainActor
  func testAMicRuleForTheRouteIsAppliedWhenATakeStarts() {
    let app = launch()
    app.tabBars.buttons["Settings"].tap()
    let headset = app.buttons.matching(identifier: "settings.mic.choice").matching(
      NSPredicate(format: "label CONTAINS %@", "Fake Headset")
    ).firstMatch
    XCTAssertTrue(waitForPresence(headset, timeout: 10))
    scrollSettings(to: headset, in: app)
    headset.tap()
    XCTAssertTrue(headset.isSelected, "the chosen input is checked")

    app.tabBars.buttons["History"].tap()
    element(app, "record.start").tap()
    XCTAssertTrue(waitForPresence(element(app, "take.screen"), timeout: 10))
    XCTAssertEqual(element(app, "take.microphone").value as? String, "Fake Headset", "the rule picked the input")
    discardTake(in: app)
  }

  @MainActor
  func testSpokenRepliesIsAToggleInSettings() {
    let app = launch()
    app.tabBars.buttons["Settings"].tap()
    let toggle = app.switches["settings.spokenReplies"]
    XCTAssertTrue(waitForPresence(toggle, timeout: 10))
    scrollSettings(to: toggle, in: app)
    XCTAssertEqual(toggle.value as? String, "0")
    // The switch sits at the row's trailing edge; a tap in the middle of the row would hit its label.
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    XCTAssertEqual(app.switches["settings.spokenReplies"].value as? String, "1")
  }
}
