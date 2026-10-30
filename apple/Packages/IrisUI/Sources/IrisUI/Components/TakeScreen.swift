import SwiftUI

/// The words of the take screen, localized by the caller.
public struct TakeScreenLabels: Sendable {
  public var recording: String
  public var paused: String
  public var stop: String
  public var discard: String
  public var pause: String
  public var resume: String
  public var microphone: String
  public var minimize: String

  public init(
    recording: String, paused: String, stop: String, discard: String, pause: String, resume: String,
    microphone: String, minimize: String
  ) {
    self.recording = recording
    self.paused = paused
    self.stop = stop
    self.discard = discard
    self.pause = pause
    self.resume = resume
    self.microphone = microphone
    self.minimize = minimize
  }
}

/// The full-screen take (round 2): the mode it will be sent as, the running time, the input level, the microphone in use,
/// and the controls. The take itself lives with the caller; this view only shows it.
public struct TakeScreen: View {
  private let isPaused: Bool
  private let start: Date
  private let frozenAt: Date?
  private let modeLabel: String
  private let inputName: String?
  private let levels: [Float]
  private let notice: String?
  private let labels: TakeScreenLabels
  private let onMinimize: () -> Void
  private let onPickInput: () -> Void
  private let onTogglePause: () -> Void
  private let onStop: () -> Void
  private let onDiscard: () -> Void

  public init(
    isPaused: Bool, start: Date, frozenAt: Date? = nil, modeLabel: String, inputName: String?, levels: [Float],
    notice: String? = nil, labels: TakeScreenLabels, onMinimize: @escaping () -> Void,
    onPickInput: @escaping () -> Void, onTogglePause: @escaping () -> Void, onStop: @escaping () -> Void,
    onDiscard: @escaping () -> Void
  ) {
    self.isPaused = isPaused
    self.start = start
    self.frozenAt = frozenAt
    self.modeLabel = modeLabel
    self.inputName = inputName
    self.levels = levels
    self.notice = notice
    self.labels = labels
    self.onMinimize = onMinimize
    self.onPickInput = onPickInput
    self.onTogglePause = onTogglePause
    self.onStop = onStop
    self.onDiscard = onDiscard
  }

  public var body: some View {
    VStack(spacing: Theme.Spacing.xl) {
      topBar
      Text(verbatim: modeLabel)
        .themeFont(.subheadline, weight: .medium)
        .foregroundStyle(Theme.Accent.onFill)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.snug)
        .background(Theme.Accent.fill, in: .capsule)
      Spacer(minLength: 0)
      ElapsedTimerText(start: start, frozenAt: frozenAt)
        .font(.system(size: 72, weight: .light))
        .foregroundStyle(Theme.Ink.primary)
        .minimumScaleFactor(0.6)
        .accessibilityIdentifier("take.timer")
      LevelWaveform(levels: levels, isActive: !isPaused)
        .frame(height: 96)
      if let notice {
        Text(verbatim: notice)
          .themeFont(.footnote)
          .foregroundStyle(Theme.Status.bad)
          .multilineTextAlignment(.center)
          .accessibilityIdentifier("take.notice")
      }
      Spacer(minLength: 0)
      microphoneButton
      controls
    }
    .padding(.horizontal, Theme.Spacing.lg)
    .padding(.vertical, Theme.Spacing.lg)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.Surface.background)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("take.screen")
  }

  private var topBar: some View {
    ZStack {
      HStack(spacing: Theme.Spacing.sm) {
        Image(systemName: isPaused ? "pause.fill" : "circle.fill")
          .font(.system(size: isPaused ? 12 : 9, weight: .bold))
          .foregroundStyle(isPaused ? Theme.Ink.muted : Theme.Status.bad)
          .accessibilityHidden(true)
        Text(verbatim: isPaused ? labels.paused : labels.recording)
          .themeFont(.footnote, weight: .semibold)
          .textCase(.uppercase)
          .foregroundStyle(isPaused ? Theme.Ink.muted : Theme.Status.bad)
      }
      HStack {
        Button(action: onMinimize) {
          Image(systemName: "chevron.down")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.Ink.primary)
            .frame(width: 44, height: 44)
            .glassEffect(.regular, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(labels.minimize)
        .accessibilityIdentifier("take.minimize")
        Spacer()
      }
    }
  }

  private var microphoneButton: some View {
    Button(action: onPickInput) {
      HStack(spacing: Theme.Spacing.sm) {
        Image(systemName: "mic")
          .accessibilityHidden(true)
        Text(verbatim: inputName ?? labels.microphone)
          .lineLimit(1)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 11, weight: .semibold))
          .accessibilityHidden(true)
      }
      .themeFont(.subheadline, weight: .medium)
      .foregroundStyle(Theme.Ink.primary)
      .padding(.horizontal, Theme.Spacing.lg)
      .frame(height: 40)
      .glassEffect(.regular, in: .capsule)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(labels.microphone)
    .accessibilityValue(inputName ?? "")
    .accessibilityIdentifier("take.microphone")
  }

  private var controls: some View {
    HStack(spacing: 26) {
      Button(action: onTogglePause) {
        Image(systemName: isPaused ? "play.fill" : "pause.fill")
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(Theme.Ink.primary)
          .frame(width: 56, height: 56)
          .glassEffect(.regular, in: .circle)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isPaused ? labels.resume : labels.pause)
      .accessibilityIdentifier("take.pause")

      Button(action: onStop) {
        Image(systemName: "stop.fill")
          .font(.system(size: 30, weight: .bold))
          .foregroundStyle(Theme.Accent.onFill)
          .frame(width: 84, height: 84)
          .background(Theme.Status.bad, in: .circle)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(labels.stop)
      .accessibilityIdentifier("take.stop")

      Button(action: onDiscard) {
        Image(systemName: "xmark")
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(Theme.Ink.primary)
          .frame(width: 56, height: 56)
          .glassEffect(.regular, in: .circle)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(labels.discard)
      .accessibilityIdentifier("take.discard")
    }
    .padding(.bottom, Theme.Spacing.md)
  }
}
