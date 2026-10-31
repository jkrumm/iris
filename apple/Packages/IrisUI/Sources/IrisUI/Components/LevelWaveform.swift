import SwiftUI

/// The input level of a take as a row of bars, newest on the right. `levels` are 0...1 (tap RMS); a quiet bar keeps a
/// minimum height so the row reads as a waveform even in silence.
public struct LevelWaveform: View {
  private let levels: [Float]
  private let isActive: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(levels: [Float], isActive: Bool = true) {
    self.levels = levels
    self.isActive = isActive
  }

  /// The newest bars that fit `width` (bar and gap are both `xs`); a narrower row drops the oldest, never clips a bar.
  private func visibleLevels(fitting width: CGFloat) -> ArraySlice<Float> {
    let slot = Theme.Spacing.xs * 2
    let fitting = max(Int(((width + Theme.Spacing.xs) / slot).rounded(.down)), 0)
    return levels.suffix(fitting)
  }

  public var body: some View {
    GeometryReader { proxy in
      let bars = visibleLevels(fitting: proxy.size.width)
      HStack(alignment: .center, spacing: Theme.Spacing.xs) {
        ForEach(Array(bars.enumerated()), id: \.offset) { _, level in
          Capsule()
            .fill(isActive ? Theme.Accent.tint : Theme.Ink.faint)
            .frame(width: Theme.Spacing.xs, height: max(4, CGFloat(min(max(level, 0), 1)) * proxy.size.height))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .animation(reduceMotion ? nil : .linear(duration: 0.1), value: levels)
    }
    .accessibilityHidden(true)
  }
}
