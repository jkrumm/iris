import SwiftUI

/// One icon of the recording controls (Live Activity and Dynamic Island). The widget wraps each in a `Button(intent:)`;
/// the snapshot tests show the labels alone.
public struct ActivityControlLabel: View {
  public enum Kind: Sendable {
    case stop, switchInput, pause, resume
    /// Speaks the finished memo's reply (the done card's action).
    case play
  }

  /// The height of a control in the row (`la.css` `.btns .btn`).
  private static let height: CGFloat = 38

  private let kind: Kind
  private let title: String
  private let onDark: Bool

  /// `onDark` is the Dynamic Island (always black); the Lock Screen card follows the appearance.
  public init(_ kind: Kind, title: String, onDark: Bool = true) {
    self.kind = kind
    self.title = title
    self.onDark = onDark
  }

  private var iconInk: Color { onDark ? .white : Theme.Ink.primary }
  private var iconFill: Color { onDark ? Color.white.opacity(0.18) : Theme.Surface.subtle }

  public var body: some View {
    switch kind {
    case .stop:
      Label(title, systemImage: "stop.fill")
        .labelStyle(.titleAndIcon)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: Self.height)
        .background(Theme.Status.bad.opacity(0.85), in: .capsule)
    case .switchInput:
      // No single SF Symbol means "swap the microphone": a mic with the swap arrows beside it.
      HStack(spacing: Theme.Spacing.tick) {
        Image(systemName: "mic.fill")
        Image(systemName: "arrow.left.arrow.right")
          .font(.system(size: 11, weight: .bold))
      }
      .font(.system(size: 16, weight: .semibold))
      .foregroundStyle(iconInk)
      .frame(width: 56, height: Self.height)
      .background(iconFill, in: .capsule)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(title)
    case .pause:
      icon("pause.fill")
    case .resume:
      icon("play.fill")
    case .play:
      Label(title, systemImage: "speaker.wave.2.fill")
        .labelStyle(.titleAndIcon)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(iconInk)
        .frame(maxWidth: .infinity, minHeight: Self.height)
        .background(iconFill, in: .capsule)
    }
  }

  private func icon(_ name: String) -> some View {
    Image(systemName: name)
      .font(.system(size: 17, weight: .semibold))
      .foregroundStyle(iconInk)
      .frame(width: 56, height: Self.height)
      .background(iconFill, in: .capsule)
      .accessibilityLabel(title)
  }
}

/// The recording controls in a row: Stop takes the room, the mic swap and the pause are icons.
public struct ActivityControlsRow<Stop: View, SwitchInput: View, Pause: View>: View {
  private let stop: Stop
  private let switchInput: SwitchInput
  private let pause: Pause

  public init(
    @ViewBuilder stop: () -> Stop, @ViewBuilder switchInput: () -> SwitchInput, @ViewBuilder pause: () -> Pause
  ) {
    self.stop = stop()
    self.switchInput = switchInput()
    self.pause = pause()
  }

  public var body: some View {
    HStack(spacing: Theme.Spacing.sm) {
      stop
      switchInput
      pause
    }
  }
}
