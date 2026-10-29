import SwiftUI

/// The running time of a take or a memo: counts up from `start` on its own (`Text(timerInterval:)`, so a Live Activity
/// needs no ticking state). With `frozenAt` it stands still at that instant: a paused take, and the snapshot tests.
public struct ElapsedTimerText: View {
  private let start: Date
  private let frozenAt: Date?

  public init(start: Date, frozenAt: Date? = nil) {
    self.start = start
    self.frozenAt = frozenAt
  }

  public var body: some View {
    Text(
      timerInterval: start...max(start, frozenAt ?? .distantFuture), pauseTime: frozenAt, countsDown: false,
      showsHours: false
    )
    .monospacedDigit()
    .contentTransition(.numericText())
  }
}
