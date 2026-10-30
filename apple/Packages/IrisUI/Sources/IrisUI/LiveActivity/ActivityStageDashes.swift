import SwiftUI

/// The four stages of a memo (record, upload, process, done) as dashes: filled for the ones behind it, half-filled for the
/// current one. A stage finishing fills its dash with a short animation, which the system plays when the activity updates.
public struct ActivityStageDashes: View {
  private let phase: ActivityPhase
  private let onDark: Bool

  public init(phase: ActivityPhase, onDark: Bool = false) {
    self.phase = phase
    self.onDark = onDark
  }

  public var body: some View {
    if let stage = phase.stage {
      HStack(spacing: Theme.Spacing.xs) {
        ForEach(0..<4, id: \.self) { index in
          Capsule()
            .fill(fill(at: index, stage: stage))
            .frame(height: 4)
        }
      }
      .animation(.smooth(duration: 0.4), value: stage)
      .accessibilityHidden(true)
    }
  }

  private func fill(at index: Int, stage: Int) -> Color {
    let tint = onDark ? Color(red: 0.64, green: 0.76, blue: 0.94) : Theme.Accent.tint
    if index < stage || stage == 3 { return tint }
    if index == stage { return tint.opacity(0.45) }
    return onDark ? Color.white.opacity(0.22) : Theme.Surface.border
  }
}
