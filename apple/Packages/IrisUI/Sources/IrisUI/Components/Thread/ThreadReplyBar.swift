import SwiftUI

/// The bottom bar of a conversation, one row. Idle: a text field for a typed reply, then hold to talk (reply by voice) and a
/// locked recording (mic with a lock) that keeps recording without a finger on the screen; once the field holds text, a send
/// button takes the place of both. Holding past the first touch starts a take, and the hold control grows to the full width
/// (the field and the lock leave); releasing sends it, sliding up before releasing cancels it. The locked recording starts with
/// a tap and ends with the send button, or the cross to discard it. Both voice takes go through the same `onHoldBegan` /
/// `onHoldEnded`. VoiceOver gets a plain toggle instead of a hold (the hint says so).
public struct ThreadReplyBar: View {
  @Binding private var text: String
  private let holdStartedAt: Date?
  private let isVoiceAvailable: Bool
  private let isTextEnabled: Bool
  private let onSend: () -> Void
  private let onHoldBegan: () -> Void
  private let onHoldEnded: (_ cancelled: Bool) -> Void

  @State private var began = false
  @State private var isCancelling = false
  @State private var lock = VoiceTakeLock()

  private static let cancelDistance: CGFloat = 70
  private static let buttonSize: CGFloat = 56

  /// - Parameters:
  ///   - text: The draft of a typed reply. The app owns it, the bar edits it.
  ///   - holdStartedAt: When the take in progress began; `nil` when idle. The app owns it, the bar only shows it.
  ///   - isVoiceAvailable: `false` while the app has no capture to talk to; the voice buttons are then disabled.
  ///   - isTextEnabled: `false` while a typed reply cannot go out (the thread has not loaded); the field and send are disabled.
  ///   - onSend: The send button, or return in the field. The app takes the draft from its model.
  public init(
    text: Binding<String>, holdStartedAt: Date?, isVoiceAvailable: Bool, isTextEnabled: Bool = true,
    onSend: @escaping () -> Void, onHoldBegan: @escaping () -> Void,
    onHoldEnded: @escaping (_ cancelled: Bool) -> Void
  ) {
    _text = text
    self.holdStartedAt = holdStartedAt
    self.isVoiceAvailable = isVoiceAvailable
    self.isTextEnabled = isTextEnabled
    self.onSend = onSend
    self.onHoldBegan = onHoldBegan
    self.onHoldEnded = onHoldEnded
  }

  private var isRecording: Bool { holdStartedAt != nil }
  private var isLockedRecording: Bool { isRecording && lock.isLocked }
  private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  /// Text takes the mic and the lock's place; a take in progress wins, so the hold control never changes its place mid-gesture.
  private var showsSend: Bool { hasText && !isRecording }

  public var body: some View {
    GlassEffectContainer(spacing: Theme.Spacing.barGap) {
      HStack(spacing: Theme.Spacing.barGap) {
        if isLockedRecording {
          lockedBar
        } else {
          if !isRecording { field }
          if showsSend {
            sendButton
          } else {
            // One view in idle and while recording (only its width changes), so the running DragGesture is never torn down.
            holdPill
            if !isRecording { lockButton }
          }
        }
      }
    }
    .padding(.horizontal, Theme.Spacing.barInset)
    .padding(.vertical, Theme.Spacing.sm)
    .hidesRecordAccessory()
    .animation(.snappy, value: isRecording)
    .animation(.snappy, value: showsSend)
    // A take the app ended on its own (a cancel on disappear) never reaches the gesture's `onEnded`.
    .onChange(of: holdStartedAt) {
      lock.takeChanged(isRecording: holdStartedAt != nil)
      guard holdStartedAt == nil else { return }
      began = false
      isCancelling = false
    }
  }

  // MARK: Idle

  /// The typed reply: a glass capsule that grows to a rounded box with its lines.
  private var field: some View {
    TextField(text: $text, axis: .vertical) {
      Text("Reply", bundle: #bundle, comment: "Placeholder of the reply field in a conversation")
    }
    .lineLimit(1...5)
    .submitLabel(.send)
    .onSubmit { if hasText { onSend() } }
    .disabled(!isTextEnabled)
    .themeFont(.callout)
    .foregroundStyle(Theme.Ink.primary)
    .padding(.horizontal, Theme.Spacing.inset)
    .padding(.vertical, Theme.Spacing.snug)
    .frame(maxWidth: .infinity, minHeight: Self.buttonSize, alignment: .leading)
    .glassEffect(.regular, in: .rect(cornerRadius: Self.buttonSize / 2))
    .accessibilityIdentifier("thread.reply.field")
  }

  private var sendButton: some View {
    Button(action: onSend) {
      Image(systemName: "arrow.up")
        .font(.system(size: 20, weight: .bold))
        .frame(width: Self.buttonSize, height: Self.buttonSize)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.tint(Theme.Accent.fill).interactive(), in: .circle)
    .foregroundStyle(Theme.Accent.onFill)
    .disabled(!isTextEnabled)
    .accessibilityLabel(
      Text("Send", bundle: #bundle, comment: "VoiceOver label of the button that sends a typed reply")
    )
    .accessibilityIdentifier("thread.reply.send")
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

  /// Hold to talk: the mic as an icon on a circle-sized capsule while idle; the full width with the timer and the release hint
  /// while the finger is down.
  private var holdPill: some View {
    HStack(spacing: Theme.Spacing.cozy) {
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
    .frame(maxWidth: isRecording ? .infinity : Self.buttonSize, minHeight: Self.buttonSize)
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
    HStack(spacing: Theme.Spacing.barGap) {
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

      HStack(spacing: Theme.Spacing.cozy) {
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
          .padding(Theme.Spacing.tick)
          .background(.background, in: .circle)
          .offset(x: 9, y: 7)
      }
      .accessibilityHidden(true)
  }
}
