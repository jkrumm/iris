import XCTest

extension XCUIElement {
  /// Scrolls `list` in small, slow drags until the middle of this element is in the clear band of the screen: below the
  /// navigation bar, search field and filter chips, above the tab bar and the record control that float over the list. A
  /// tap or a drag at the middle of a row under either would reach them instead of the row.
  @MainActor
  func scrollIntoClearBand(of list: XCUIElement, app: XCUIApplication, maxDrags: Int = 12) {
    let height = app.frame.height
    for _ in 0..<maxDrags where exists {
      let middle = frame.midY
      if middle > height * 0.40 && middle < height * 0.66 { return }
      // Positive: the row has to move up. One drag moves it by at most a quarter of the screen.
      let delta = max(-height * 0.25, min(height * 0.25, middle - height * 0.53))
      let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(
        CGVector(dx: 0, dy: height * 0.53 + delta / 2))
      let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(
        CGVector(dx: 0, dy: height * 0.53 - delta / 2))
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
    }
  }
}
