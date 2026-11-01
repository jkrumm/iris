import SwiftUI
import Testing

@testable import IrisUI

struct SparklineTests {
  @Test("the mockup's mapping: a peak sits 5 pt from the top, a zero 3 pt from the bottom")
  func insets() {
    #expect(Sparkline.y(of: 4, maximum: 4, height: 26) == 5)
    #expect(Sparkline.y(of: 0, maximum: 4, height: 26) == 23)
  }

  @Test("a series of zeros stays on the baseline instead of dividing by zero")
  func allZero() {
    let path = Sparkline(points: [0, 0, 0]).path(in: CGRect(x: 0, y: 0, width: 100, height: 26))
    #expect(path.boundingRect.height == 0)
    #expect(path.boundingRect.maxY == 23)
  }

  @Test("the points span the full width, one per period")
  func spansTheWidth() {
    let rect = Sparkline(points: [1, 2, 3, 4]).path(in: CGRect(x: 0, y: 0, width: 90, height: 26)).boundingRect
    #expect(rect.minX == 0)
    #expect(rect.maxX == 90)
  }

  @Test("a single period draws a dot, none draws nothing")
  func degenerate() {
    let rect = CGRect(x: 0, y: 0, width: 100, height: 26)
    #expect(!Sparkline(points: [3]).path(in: rect).isEmpty)
    #expect(Sparkline(points: []).path(in: rect).isEmpty)
  }
}
