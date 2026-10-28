import SwiftUI

/// How far the pipeline has come: one dash per step, `completed` of them filled.
public struct StepProgress: Equatable, Sendable {
  public let completed: Int
  public let total: Int

  public init(completed: Int, total: Int) {
    self.total = max(total, 0)
    self.completed = min(max(completed, 0), self.total)
  }
}

/// The step-progress dashes on an in-flight History row: filled for a finished step, half-filled for the one
/// running, empty for the rest. A step finishing fills its dash with a short fade (none under Reduce Motion).
public struct StepProgressDashes: View {
  private let progress: StepProgress
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(progress: StepProgress) {
    self.progress = progress
  }

  public var body: some View {
    HStack(spacing: 2) {
      ForEach(0..<progress.total, id: \.self) { index in
        Capsule()
          .fill(fill(at: index))
          .frame(width: 10, height: 3)
      }
    }
    .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: progress)
    .accessibilityHidden(true)
  }

  private func fill(at index: Int) -> Color {
    if index < progress.completed { return Theme.Accent.tint }
    if index == progress.completed { return Theme.Accent.tint.opacity(0.4) }
    return Theme.Surface.border
  }
}
