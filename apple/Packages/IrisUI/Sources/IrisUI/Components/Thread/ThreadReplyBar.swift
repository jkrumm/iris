import SwiftUI

/// The bottom bar of a thread, one row of icons: a keyboard (reply by text), hold to talk (reply by voice), and a locked
/// recording (mic with a lock) that keeps recording without a finger on the screen. Holding past the first touch starts a
/// take; releasing sends it, sliding up before releasing cancels it. The locked recording starts with a tap and ends with
/// the send button, or the cross to discard it. Both voice takes go through the same `onHoldBegan` / `onHoldEnded`.
/// VoiceOver gets a plain toggle instead of a hold (the hint says so).
public struct ThreadReplyBar: View {
  private let holdStartedAt: Date?
  private let isVoiceAvailable: Bool
  private let onType: () -> Void
  private let onHoldBegan: () -> Void
  private let onHoldEnded: (_ cancelled: Bool) -> Void

  @State private var began = false
  @State private var isCancelling = false
  @State private var lock = VoiceTakeLock()

  private static let cancelDistance: CGFloat = 70
  private static let buttonSize: CGFloat = 56

  /// - Parameters:
  ///   - holdStartedAt: When the take in progress began; `nil` when idle. The app owns it, the bar only shows it.
  ///   - isVoiceAvailable: `false` while the app has no capture to talk to; the voice buttons are then disabled.
  public init(
    holdStartedAt: Date?, isVoiceAvailable: Bool, onType: @escaping () -> Void, onHoldBegan: @escaping () -> Void,
    onHoldEnded: @escaping (_ cancelled: Bool) -> Void
  ) {
    self.holdStartedAt = holdStartedAt
    self.isVoiceAvailable = isVoiceAvailable
    self.onType = onType
    self.onHoldBegan = onHoldBegan
    self.onHoldEnded = onHoldEnded
  }

  private var isRecording: Bool { holdStartedAt != nil }
  private var isLockedRecording: Bool { isRecording && lock.isLocked }

  public var body: some View {
    GlassEffectContainer(spacing: Theme.Spacing.md) {
      HStack(spacing: Theme.Spacing.md) {
        if isLockedRecording {
          lockedBar
        } else {
          if !isRecording { keyboardButton }
          holdPill
          if !isRecording { lockButton }
        }
      }
    }
    .padding(.horizontal, Theme.Spacing.lg)
    .padding(.vertical, Theme.Spacing.sm)
    .animation(.snappy, value: isRecording)
    // A take the app ended on its own (a cancel on disappear) never reaches the gesture's `onEnded`.
    .onChange(of: holdStartedAt) {
      lock.takeChanged(isRecording: holdStartedAt != nil)
      guard holdStartedAt == nil else { return }
      began = false
      isCancelling = false
    }
  }

  // MARK: Idle

  private var keyboardButton: some View {
    Button(action: onType) {
      Image(systemName: "keyboard")
        .font(.system(size: 20))
        .frame(width: Self.buttonSize, height: Self.buttonSize)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: .circle)
    .foregroundStyle(Theme.Ink.primary)
    .accessibilityLabel(Text("Reply by text", bundle: #bundle, comment: "VoiceOver label of the keyboard button"))
    .accessibilityIdentifier("thread.reply.text")
  }

  private var lockButton: some View {
    Button {
      lock.request()
      onHoldBegan()
    } label: {
      LockedMicIcon()
        .frame(width: Self.buttonSize, height: Self.buttonSize)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.tint(Theme.Accent.tint.opacity(0.18)).interactive(), in: .circle)
    .foregroundStyle(Theme.Accent.tint)
    .disabled(!isVoiceAvailable)
    .opacity(isVoiceAvailable ? 1 : 0.45)
    .accessibilityLabel(
      Text("Record continuously", bundle: #bundle, comment: "VoiceOver label of the locked-recording button")
    )
    .accessibilityHint(
      Text(
        "Tap to start, tap send when done", bundle: #bundle, comment: "VoiceOver hint of the locked-recording button")
    )
    .accessibilityIdentifier("thread.reply.lock")
  }

  /// Hold to talk: the mic as an icon while idle; the timer and the release hint while the finger is down.
  private var holdPill: some View {
    HStack(spacing: Theme.Spacing.md) {
      Image(systemName: isCancelling ? "xmark" : "mic.fill")
        .font(.system(size: 22, weight: .semibold))
        .contentTransition(.symbolEffect(.replace))
      if let holdStartedAt {
        elapsed(since: holdStartedAt)
        Text(
          isCancelling ? "Release to cancel" : "Release to send · slide up to cancel", bundle: #bundle,
          comment: "Hint while holding the talk button"
        )
        .themeFont(.footnote)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      }
    }
    .themeFont(.callout, weight: .semibold)
    .foregroundStyle(isRecording ? Theme.Status.bad : Theme.Accent.tint)
    .frame(maxWidth: .infinity, minHeight: Self.buttonSize)
    .glassEffect(
      .regular.tint(isRecording ? Theme.Status.bad.opacity(0.2) : Theme.Accent.tint.opacity(0.18)).interactive(),
      in: .capsule
    )
    .opacity(isVoiceAvailable ? 1 : 0.45)
    .contentShape(.capsule)
    .gesture(hold, isEnabled: isVoiceAvailable)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      isRecording
        ? Text("Stop and send", bundle: #bundle, comment: "VoiceOver label while a voice reply is recording")
        : Text("Reply by voice", bundle: #bundle, comment: "VoiceOver label of the hold-to-talk button")
    )
    // The VoiceOver action toggles (a hold is not possible with it), so the hint says what the next activation does.
    .accessibilityHint(
      isRecording
        ? Text("Double-tap to send", bundle: #bundle, comment: "VoiceOver hint of the talk button while recording")
        : Text(
          "Double-tap to start recording, double-tap again to send", bundle: #bundle,
          comment: "VoiceOver hint of the talk button while idle")
    )
    .accessibilityAddTraits(.isButton)
    .accessibilityAction {
      if !isRecording {
        lock.beginUnlocked()
        onHoldBegan()
      } else {
        onHoldEnded(false)
      }
    }
    .accessibilityIdentifier("thread.reply.voice")
  }

  // MARK: Locked recording

  /// Cross to discard, the running timer, and the send button.
  private var lockedBar: some View {
    HStack(spacing: Theme.Spacing.md) {
      Button {
        onHoldEnded(true)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 20, weight: .semibold))
          .frame(width: Self.buttonSize, height: Self.buttonSize)
      }
      .buttonStyle(.plain)
      .glassEffect(.regular.interactive(), in: .circle)
      .foregroundStyle(Theme.Ink.primary)
      .accessibilityLabel(
        Text("Discard recording", bundle: #bundle, comment: "VoiceOver label of the cross of a locked recording")
      )
      .accessibilityIdentifier("thread.reply.lock.cancel")

      HStack(spacing: Theme.Spacing.md) {
        Image(systemName: "mic.fill").symbolEffect(.pulse)
        if let holdStartedAt { elapsed(since: holdStartedAt) }
      }
      .themeFont(.callout, weight: .semibold)
      .foregroundStyle(Theme.Status.bad)
      .frame(maxWidth: .infinity, minHeight: Self.buttonSize)
      .glassEffect(.regular.tint(Theme.Status.bad.opacity(0.2)), in: .capsule)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(Text("Recording", bundle: #bundle, comment: "VoiceOver label of a locked recording"))
      .accessibilityIdentifier("thread.reply.lock.timer")

      Button {
        onHoldEnded(false)
      } label: {
        Image(systemName: "arrow.up")
          .font(.system(size: 20, weight: .bold))
          .frame(width: Self.buttonSize, height: Self.buttonSize)
      }
      .buttonStyle(.plain)
      .glassEffect(.regular.tint(Theme.Accent.fill).interactive(), in: .circle)
      .foregroundStyle(Theme.Accent.onFill)
      .accessibilityLabel(
        Text("Stop and send", bundle: #bundle, comment: "VoiceOver label while a voice reply is recording")
      )
      .accessibilityIdentifier("thread.reply.lock.send")
    }
  }

  private func elapsed(since start: Date) -> some View {
    TimelineView(.periodic(from: start, by: 1)) { context in
      let seconds = max(context.date.timeIntervalSince(start), 0)
      Text(verbatim: PlayerTime.string(seconds)).monospacedDigit()
    }
  }

  private var hold: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        if !began {
          began = true
          lock.beginUnlocked()
          onHoldBegan()
        }
        isCancelling = value.translation.height < -Self.cancelDistance
      }
      .onEnded { value in
        let cancelled = value.translation.height < -Self.cancelDistance
        began = false
        isCancelling = false
        onHoldEnded(cancelled)
      }
  }
}

/// "Recording, locked": the mic with a lock badge. No single SF Symbol says it, so two are composed.
struct LockedMicIcon: View {
  var body: some View {
    Image(systemName: "mic.fill")
      .font(.system(size: 22, weight: .semibold))
      .overlay(alignment: .bottomTrailing) {
        Image(systemName: "lock.fill")
          .font(.system(size: 11, weight: .bold))
          .padding(3)
          .background(.background, in: .circle)
          .offset(x: 9, y: 7)
      }
      .accessibilityHidden(true)
  }
}
