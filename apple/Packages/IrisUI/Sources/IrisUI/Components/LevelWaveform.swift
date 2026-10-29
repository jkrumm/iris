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

  public var body: some View {
    GeometryReader { proxy in
      HStack(alignment: .center, spacing: 3) {
        ForEach(levels.indices, id: \.self) { index in
          Capsule()
            .fill(isActive ? Theme.Accent.tint : Theme.Ink.faint)
            .frame(width: 3, height: max(4, CGFloat(min(max(levels[index], 0), 1)) * proxy.size.height))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .animation(reduceMotion ? nil : .linear(duration: 0.1), value: levels)
    }
    .accessibilityHidden(true)
  }
}
