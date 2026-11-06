import SwiftUI

/// The "Play reply" control in the footer of Iris's bubble: a speaker with its label, a stop square with "Stop reply" while the
/// reply speaks. The playback lives with the caller.
public struct ReplyPlayButton: View {
  private let isPlaying: Bool
  private let onToggle: () -> Void

  public init(isPlaying: Bool, onToggle: @escaping () -> Void) {
    self.isPlaying = isPlaying
    self.onToggle = onToggle
  }

  public var body: some View {
    Button(action: onToggle) {
      Label {
        if isPlaying {
          Text("Stop reply", bundle: #bundle, comment: "Label of the stop button while the reply plays")
        } else {
          Text("Play reply", bundle: #bundle, comment: "Label of the button that speaks the reply")
        }
      } icon: {
        Image(systemName: isPlaying ? "stop.fill" : "speaker.wave.2")
      }
      .themeFont(.footnote, weight: .semibold)
      .foregroundStyle(Theme.Accent.tint)
      .frame(minHeight: Theme.Spacing.tapTarget, alignment: .leading)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("detail.action.play")
  }
}
