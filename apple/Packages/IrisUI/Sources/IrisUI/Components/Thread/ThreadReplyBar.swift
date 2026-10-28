import SwiftUI

/// The bottom bar of a thread: a keyboard button (reply by text) and a hold-to-talk pill (reply by voice). Holding past
/// the first touch starts a take; releasing sends it, sliding up before releasing cancels it. VoiceOver gets a plain
/// toggle instead of a hold.
public struct ThreadReplyBar: View {
  private let holdStartedAt: Date?
  private let isVoiceAvailable: Bool
  private let onType: () -> Void
  private let onHoldBegan: () -> Void
  private let onHoldEnded: (_ cancelled: Bool) -> Void

  @State private var began = false
  @State private var isCancelling = false

  private static let cancelDistance: CGFloat = 70

  /// - Parameters:
  ///   - holdStartedAt: When the take in progress began; `nil` when idle. The app owns it, the bar only shows it.
  ///   - isVoiceAvailable: `false` while the app has no capture to talk to; the pill is then disabled.
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

  public var body: some View {
    HStack(spacing: Theme.Spacing.md) {
      Button(action: onType) {
        Image(systemName: "keyboard")
          .font(.system(size: 20))
          .frame(width: 56, height: 56)
      }
      .buttonStyle(.plain)
      .glassEffect(.regular.interactive(), in: .circle)
      .foregroundStyle(Theme.Ink.primary)
      .disabled(holdStartedAt != nil)
      .accessibilityLabel(Text("Reply by text", bundle: #bundle, comment: "VoiceOver label of the keyboard button"))
      .accessibilityIdentifier("thread.reply.text")

      pill
    }
    .padding(.horizontal, Theme.Spacing.lg)
    .padding(.vertical, Theme.Spacing.sm)
    .animation(.snappy, value: holdStartedAt != nil)
  }

  private var pill: some View {
    HStack(spacing: Theme.Spacing.md) {
      Image(systemName: isCancelling ? "xmark" : "mic.fill")
        .contentTransition(.symbolEffect(.replace))
      if let holdStartedAt {
        TimelineView(.periodic(from: holdStartedAt, by: 1)) { context in
          let seconds = max(context.date.timeIntervalSince(holdStartedAt), 0)
          Text(verbatim: PlayerTime.string(seconds)).monospacedDigit()
        }
        Text(
          isCancelling ? "Release to cancel" : "Release to send · slide up to cancel", bundle: #bundle,
          comment: "Hint while holding the talk button"
        )
        .themeFont(.footnote)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      } else {
        Text("Hold to talk", bundle: #bundle, comment: "The hold-to-talk button of a thread")
      }
    }
    .themeFont(.callout, weight: .semibold)
    .foregroundStyle(holdStartedAt == nil ? Theme.Accent.tint : Theme.Status.bad)
    .frame(maxWidth: .infinity, minHeight: 56)
    .glassEffect(
      .regular.tint(holdStartedAt == nil ? Theme.Accent.tint.opacity(0.18) : Theme.Status.bad.opacity(0.2))
        .interactive(), in: .capsule
    )
    .opacity(isVoiceAvailable ? 1 : 0.45)
    .contentShape(.capsule)
    .gesture(hold, isEnabled: isVoiceAvailable)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      holdStartedAt == nil
        ? Text("Reply by voice", bundle: #bundle, comment: "VoiceOver label of the hold-to-talk button")
        : Text("Stop and send", bundle: #bundle, comment: "VoiceOver label while a voice reply is recording")
    )
    .accessibilityAddTraits(.isButton)
    .accessibilityAction {
      if holdStartedAt == nil { onHoldBegan() } else { onHoldEnded(false) }
    }
    .accessibilityIdentifier("thread.reply.voice")
  }

  private var hold: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        if !began {
          began = true
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
