import SwiftUI

/// What the inline reply player draws for one memo's reply: whether the player holds this reply (loading, playing or paused),
/// where it is, and which spoken form it plays. `.idle` is a reply nothing has started.
public struct ReplyPlayback: Equatable, Sendable {
  public var isActive: Bool
  public var isPlaying: Bool
  public var isLoading: Bool
  public var position: Double
  public var duration: Double
  /// The form the player holds; `nil` when idle or when the server's default plays (the auto-read).
  public var choice: ReplyPlayChoice?

  public init(
    isActive: Bool, isPlaying: Bool, isLoading: Bool, position: Double, duration: Double, choice: ReplyPlayChoice?
  ) {
    self.isActive = isActive
    self.isPlaying = isPlaying
    self.isLoading = isLoading
    self.position = position
    self.duration = duration
    self.choice = choice
  }

  public static let idle = ReplyPlayback(
    isActive: false, isPlaying: false, isLoading: false, position: 0, duration: 0, choice: nil)
}

/// The reply's player in the footer of Iris's bubble, in the voice-message style: a round play or pause button, the thin
/// scrubber of the recording player and the elapsed time, with a small menu that picks the spoken form (the summary or the whole
/// reply). The playback lives with the caller: `playback` comes in, toggles, form picks and seeks go out. Idle, the button plays
/// the summary and the scrubber is dimmed.
public struct ReplyPlayer: View {
  private let playback: ReplyPlayback
  private let onToggle: () -> Void
  private let onPlay: (ReplyPlayChoice) -> Void
  private let onSeek: (Double) -> Void

  @State private var draft: Double
  @State private var isScrubbing = false

  private static let playSize: CGFloat = 32

  public init(
    playback: ReplyPlayback, onToggle: @escaping () -> Void, onPlay: @escaping (ReplyPlayChoice) -> Void,
    onSeek: @escaping (Double) -> Void
  ) {
    self.playback = playback
    self.onToggle = onToggle
    self.onPlay = onPlay
    self.onSeek = onSeek
    _draft = State(initialValue: playback.position)
  }

  public var body: some View {
    HStack(spacing: Theme.Spacing.sm) {
      playButton
      scrubber
      time
      formMenu
    }
    .onChange(of: playback.position) { _, new in
      if !isScrubbing { draft = new }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("thread.reply.player")
  }

  private var shown: Double { isScrubbing ? draft : playback.position }

  private var playButton: some View {
    Button(action: onToggle) {
      ZStack {
        Circle().fill(Theme.Accent.fill)
        if playback.isLoading {
          ProgressView().controlSize(.small).tint(Theme.Accent.onFill)
        } else {
          Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.Accent.onFill)
        }
      }
      .frame(width: Self.playSize, height: Self.playSize)
      .contentShape(.circle)
    }
    .buttonStyle(.plain)
    .disabled(playback.isLoading)
    .accessibilityLabel(playLabel)
    .help(playLabel)
    .accessibilityIdentifier("thread.reply.toggle")
  }

  private var playLabel: Text {
    playback.isPlaying
      ? Text("Pause reply", bundle: #bundle, comment: "VoiceOver label of the reply player's pause button")
      : Text("Play reply", bundle: #bundle, comment: "VoiceOver label of the reply player's play button")
  }

  private var scrubber: some View {
    ThinScrubber(value: $draft, upperBound: max(playback.duration, 1)) { editing in
      isScrubbing = editing
      if !editing { onSeek(draft) }
    }
    .disabled(!playback.isActive || playback.isLoading)
    .opacity(playback.isActive ? 1 : 0.4)
    .accessibilityElement()
    .accessibilityLabel(Text("Position", bundle: #bundle, comment: "VoiceOver label of the player's timeline"))
    .accessibilityValue(
      Text(
        "\(PlayerTime.string(shown)) of \(PlayerTime.string(playback.duration))", bundle: #bundle,
        comment: "VoiceOver value of the player's timeline: elapsed of total, both as m:ss")
    )
    .accessibilityAdjustableAction { direction in
      let step = max(playback.duration / 20, 1)
      switch direction {
      case .increment: draft = min(draft + step, max(playback.duration, 1))
      case .decrement: draft = max(draft - step, 0)
      @unknown default: return
      }
      onSeek(draft)
    }
    .accessibilityIdentifier("thread.reply.slider")
  }

  /// The time left once the length is known, else the zero it starts from.
  private var time: some View {
    Text(verbatim: playback.duration > 0 ? PlayerTime.string(max(playback.duration - shown, 0)) : PlayerTime.string(0))
      .themeFont(.caption)
      .monospacedDigit()
      .foregroundStyle(Theme.Ink.muted)
      .accessibilityHidden(true)
  }

  private var formMenu: some View {
    Menu {
      Button {
        onPlay(.summary)
      } label: {
        Label {
          Text("Read the summary", bundle: #bundle, comment: "Menu item: speaks the short summary of the reply")
        } icon: {
          Image(systemName: "text.quote")
        }
      }
      .accessibilityIdentifier("thread.reply.summary")
      Button {
        onPlay(.full)
      } label: {
        Label {
          Text("Read the full reply", bundle: #bundle, comment: "Menu item: speaks the whole reply")
        } icon: {
          Image(systemName: "text.alignleft")
        }
      }
      .accessibilityIdentifier("thread.reply.full")
    } label: {
      HStack(spacing: Theme.Spacing.hair) {
        Image(systemName: playback.choice == .full ? "text.alignleft" : "text.quote")
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
      }
      .font(.system(size: 13))
      .foregroundStyle(Theme.Ink.muted)
      .frame(minWidth: Self.playSize, minHeight: Self.playSize)
      .contentShape(.rect)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .accessibilityLabel(formLabel)
    .help(formLabel)
    .accessibilityIdentifier("thread.reply.form")
  }

  private var formLabel: Text {
    Text(
      "Choose what to read", bundle: #bundle,
      comment: "VoiceOver label of the menu that picks the summary or the full reply")
  }
}
