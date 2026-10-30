import SwiftUI

/// The glyph of a phase: the compact-leading and minimal presentations of the Dynamic Island, and the header icon. It
/// changes with a symbol transition when the activity updates.
public struct IslandGlyph: View {
  private let phase: ActivityPhase
  private let onDark: Bool

  public init(phase: ActivityPhase, onDark: Bool = true) {
    self.phase = phase
    self.onDark = onDark
  }

  public var body: some View {
    Group {
      switch phase {
      case .recording:
        Circle()
          .fill(Theme.Status.bad)
          .frame(width: 9, height: 9)
          .frame(width: 16, height: 16)
      case .done:
        Image(systemName: "checkmark")
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(Theme.Status.good)
          .frame(width: 16, height: 16)
      case .needsRoute:
        Text(verbatim: "?")
          .font(.system(size: 11, weight: .heavy))
          .foregroundStyle(.black)
          .frame(width: 16, height: 16)
          .background(Theme.Status.warn, in: .circle)
      case .failed:
        Image(systemName: phase.symbol)
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(Theme.Status.warn)
          .frame(width: 16, height: 16)
      case .paused, .uploading, .processing:
        Image(systemName: phase.symbol)
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(onDark ? Color.white : Theme.Ink.secondary)
          .frame(width: 16, height: 16)
      }
    }
    .contentTransition(.symbolEffect(.replace))
    .accessibilityHidden(true)
  }
}

/// The trailing side of the compact island: the running time while recording or processing, nothing otherwise.
public struct IslandCompactTrailing: View {
  private let presentation: ActivityPresentation

  public init(_ presentation: ActivityPresentation) {
    self.presentation = presentation
  }

  public var body: some View {
    if presentation.phase.showsTimer {
      ElapsedTimerText(start: presentation.start, frozenAt: presentation.timerFrozenAt)
        .themeFont(.footnote, weight: .semibold)
        .foregroundStyle(.white)
        .frame(maxWidth: 52, alignment: .trailing)
    } else {
      Text(verbatim: presentation.modeLabel)
        .themeFont(.footnote, weight: .semibold)
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(1)
    }
  }
}

/// A stand-in for the system's Dynamic Island, for the snapshot tests and previews: a black pill (compact, minimal) or the
/// expanded card. The system draws the real one; this shows what the widget puts into its regions.
public struct IslandMock<Leading: View, Trailing: View, Bottom: View>: View {
  public enum Shape: Sendable {
    case compact, minimal, expanded
  }

  private let shape: Shape
  private let leading: Leading
  private let trailing: Trailing
  private let bottom: Bottom

  public init(
    _ shape: Shape, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing,
    @ViewBuilder bottom: () -> Bottom
  ) {
    self.shape = shape
    self.leading = leading()
    self.trailing = trailing()
    self.bottom = bottom()
  }

  public var body: some View {
    Group {
      switch shape {
      case .compact:
        HStack {
          leading
          Spacer(minLength: 120)
          trailing
        }
        .padding(.horizontal, Theme.Spacing.inset)
        .frame(width: 232, height: 37)
        .background(.black, in: .capsule)
      case .minimal:
        leading
          .frame(width: 37, height: 37)
          .background(.black, in: .circle)
      case .expanded:
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
          HStack {
            leading
            Spacer(minLength: Theme.Spacing.md)
            trailing
          }
          bottom
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.vertical, Theme.Spacing.lg)
        .frame(width: 366)
        .background(.black, in: .rect(cornerRadius: 42))
      }
    }
    .environment(\.colorScheme, .dark)
  }
}

extension IslandMock where Bottom == EmptyView {
  public init(_ shape: Shape, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
    self.init(shape, leading: leading, trailing: trailing) { EmptyView() }
  }
}
