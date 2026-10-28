import Testing

@testable import IrisUI

struct PlayerTimeTests {
  @Test(
    "m:ss under an hour, h:mm:ss from one",
    arguments: [
      (0.0, "0:00"), (12.9, "0:12"), (59.99, "0:59"), (60, "1:00"), (754, "12:34"), (3_600, "1:00:00"),
      (3_725, "1:02:05"),
      (-3, "0:00"),
    ])
  func formats(seconds: Double, expected: String) {
    #expect(PlayerTime.string(seconds) == expected)
  }
}

struct StepProgressTests {
  @Test("completed is clamped into 0...total")
  func clamps() {
    #expect(StepProgress(completed: 9, total: 5).completed == 5)
    #expect(StepProgress(completed: -1, total: 5).completed == 0)
    #expect(StepProgress(completed: 2, total: -3) == StepProgress(completed: 0, total: 0))
  }

  @Test("a waterfall row keeps its bar inside the run")
  func rowBarStaysInside() {
    let row = StepWaterfallRow(id: "act", title: "Act", phase: .done, start: 0.8, length: 0.9)
    #expect(row.start == 0.8)
    #expect(abs(row.length - 0.2) < 1e-9)
    #expect(StepWaterfallRow(id: "x", title: "X", phase: .done, start: -1, length: -1).length == 0)
  }
}
