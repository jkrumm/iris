import SwiftUI

/// Round 1's player: play/pause on the left, the scrubbable timeline with elapsed and remaining time, one 10 s-back
/// icon on the right. No speed control. The playback itself lives with the caller (`position` and `isPlaying` come
/// in; toggles and seeks go out); a bar with `isEnabled == false` still renders, dimmed.
public struct MemoPlayerBar: View {
  private let position: Double
  private let duration: Double
  private let isPlaying: Bool
  private let isEnabled: Bool
  private let onToggle: () -> Void
  private let onSeek: (Double) -> Void
  private let onSkipBack: () -> Void

  @State private var draft: Double
  @State private var isScrubbing = false

  public init(
    position: Double,
    duration: Double,
    isPlaying: Bool,
    isEnabled: Bool = true,
    onToggle: @escaping () -> Void,
    onSeek: @escaping (Double) -> Void,
    onSkipBack: @escaping () -> Void
  ) {
    self.position = position
    self.duration = duration
    self.isPlaying = isPlaying
    self.isEnabled = isEnabled
    self.onToggle = onToggle
    self.onSeek = onSeek
    self.onSkipBack = onSkipBack
    _draft = State(initialValue: position)
  }

  public var body: some View {
    HStack(spacing: Theme.Spacing.md) {
      Button(action: onToggle) {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(Theme.Accent.onFill)
          .frame(width: 44, height: 44)
          .background(Theme.Accent.fill, in: .circle)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        isPlaying
          ? Text("Pause", bundle: #bundle, comment: "VoiceOver label of the player's pause button")
          : Text("Play", bundle: #bundle, comment: "VoiceOver label of the player's play button")
      )
      .accessibilityIdentifier("detail.player.toggle")

      VStack(spacing: Theme.Spacing.xs) {
        Slider(value: $draft, in: 0...max(duration, 1)) { editing in
          isScrubbing = editing
          if !editing { onSeek(draft) }
        }
        .tint(Theme.Accent.tint)
        .accessibilityLabel(Text("Position", bundle: #bundle, comment: "VoiceOver label of the player's timeline"))
        .accessibilityValue(
          Text(
            "\(PlayerTime.string(shown)) of \(PlayerTime.string(duration))", bundle: #bundle,
            comment: "VoiceOver value of the player's timeline: elapsed of total, both as m:ss")
        )
        .accessibilityIdentifier("detail.player.slider")
        HStack {
          Text(verbatim: PlayerTime.string(shown))
          Spacer()
          Text(verbatim: "−" + PlayerTime.string(max(duration - shown, 0)))
        }
        .themeFont(.caption)
        .monospacedDigit()
        .foregroundStyle(Theme.Ink.muted)
        .accessibilityHidden(true)
      }

      Button(action: onSkipBack) {
        Image(systemName: "gobackward.10")
          .font(.system(size: 22))
          .foregroundStyle(Theme.Ink.secondary)
          .frame(width: 44, height: 44)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        Text("Back 10 seconds", bundle: #bundle, comment: "VoiceOver label of the player's skip-back button")
      )
      .accessibilityIdentifier("detail.player.back")
    }
    .padding(.horizontal, Theme.Spacing.cardInsetHorizontal)
    .padding(.vertical, Theme.Spacing.cardInsetVertical)
    .detailCard()
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.5)
    .onChange(of: position) { _, new in
      if !isScrubbing { draft = new }
    }
  }

  private var shown: Double { isScrubbing ? draft : position }
}

/// `m:ss`, or `h:mm:ss` from an hour on.
enum PlayerTime {
  static func string(_ seconds: Double) -> String {
    let total = Int(max(seconds, 0).rounded(.down))
    let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60)
    let pair = rest < 10 ? "0\(rest)" : "\(rest)"
    if hours > 0 { return "\(hours):\(minutes < 10 ? "0" : "")\(minutes):\(pair)" }
    return "\(minutes):\(pair)"
  }
}
