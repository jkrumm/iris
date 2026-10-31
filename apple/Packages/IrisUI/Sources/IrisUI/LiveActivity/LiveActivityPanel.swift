import SwiftUI

/// The body of a memo's Live Activity: the Lock Screen card and, with `style: .island`, the bottom region of the expanded
/// Dynamic Island (whose leading and trailing regions carry what the lock-screen header carries).
public struct LiveActivityPanel<Controls: View, DoneAction: View>: View {
  public enum Style: Sendable {
    case lockScreen, island
  }

  private let presentation: ActivityPresentation
  private let style: Style
  private let controls: Controls
  private let doneAction: DoneAction

  /// `controls` is shown while the phase is `recording` or `paused`; `doneAction` (Play) while it is `done`.
  public init(
    _ presentation: ActivityPresentation, style: Style = .lockScreen, @ViewBuilder controls: () -> Controls,
    @ViewBuilder doneAction: () -> DoneAction
  ) {
    self.presentation = presentation
    self.style = style
    self.controls = controls()
    self.doneAction = doneAction()
  }

  private var primary: Color { style == .island ? .white : Theme.Ink.primary }
  private var secondary: Color { style == .island ? Color.white.opacity(0.7) : Theme.Ink.secondary }

  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      if style == .lockScreen { header }
      content
      if presentation.phase == .recording || presentation.phase == .paused { controls }
      if presentation.phase == .done { doneAction }
      if let note = presentation.note { noteRow(note) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var header: some View {
    HStack(spacing: Theme.Spacing.sm) {
      ActivityPhaseTitle(presentation, onDark: false)
      Spacer(minLength: Theme.Spacing.sm)
      ActivityHeaderTrailing(presentation, onDark: false)
    }
  }

  @ViewBuilder private var content: some View {
    switch presentation.phase {
    case .recording:
      HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.inset) {
        ElapsedTimerText(start: presentation.start, frozenAt: presentation.timerFrozenAt)
          .font(.system(size: 44, weight: .light))
          .tracking(-0.44)
          .foregroundStyle(primary)
        Spacer(minLength: 0)
        if let inputName = presentation.inputName { inputChip(inputName) }
      }
    case .paused:
      HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
        Text(verbatim: presentation.phaseTitle)
          .font(.system(size: 28, weight: .light))
          .foregroundStyle(secondary)
        Spacer(minLength: 0)
        if let inputName = presentation.inputName { inputChip(inputName) }
      }
    case .uploading, .processing:
      VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        if let subtitle = presentation.subtitle {
          Text(verbatim: subtitle)
            .themeFont(.body, weight: .semibold)
            .foregroundStyle(primary)
        }
        ActivityStageDashes(phase: presentation.phase, onDark: style == .island)
      }
    case .needsRoute:
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        Text(verbatim: presentation.subtitle ?? presentation.phaseTitle)
          .themeFont(.body, weight: .semibold)
          .foregroundStyle(primary)
        if let routeChip = presentation.routeChip { chip(routeChip) }
      }
    case .done:
      VStack(alignment: .leading, spacing: Theme.Spacing.hair) {
        // First-text-baseline alignment with the same font on the mark and the headline keeps the check on the first line,
        // however far the headline wraps (round 2: the mockup's mark sat too low).
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Theme.Status.good)
            .accessibilityHidden(true)
          Text(verbatim: presentation.headline ?? presentation.phaseTitle)
            .lineLimit(2)
            .foregroundStyle(primary)
        }
        .themeFont(.body, weight: .semibold)
        if let routeChip = presentation.routeChip {
          Text(verbatim: routeChip)
            .themeFont(.footnote)
            .foregroundStyle(secondary)
        }
      }
    case .failed:
      HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(Theme.Status.warn)
          .accessibilityHidden(true)
        Text(verbatim: presentation.subtitle ?? presentation.phaseTitle)
          .lineLimit(2)
          .foregroundStyle(primary)
      }
      .themeFont(.body, weight: .semibold)
    }
  }

  private func inputChip(_ name: String) -> some View {
    HStack(spacing: Theme.Spacing.snug) {
      Image(systemName: "mic.fill").accessibilityHidden(true)
      Text(verbatim: name).lineLimit(1)
    }
    .themeFont(.footnote, weight: .medium)
    .foregroundStyle(secondary)
  }

  private func chip(_ label: String) -> some View {
    Text(verbatim: label)
      .themeFont(.footnote, weight: .medium)
      .foregroundStyle(secondary)
      .padding(.horizontal, Theme.Spacing.sm)
      .padding(.vertical, Theme.Spacing.tick)
      .background(style == .island ? Color.white.opacity(0.14) : Theme.Surface.subtle, in: .capsule)
  }

  private func noteRow(_ note: String) -> some View {
    HStack(spacing: Theme.Spacing.sm) {
      Image(systemName: "arrow.up.circle")
        .accessibilityHidden(true)
      Text(verbatim: note).lineLimit(1)
    }
    .themeFont(.footnote)
    .foregroundStyle(secondary)
    .padding(.horizontal, Theme.Spacing.md)
    .padding(.vertical, Theme.Spacing.sm)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(style == .island ? Color.white.opacity(0.09) : Theme.Surface.subtle, in: .rect(cornerRadius: 14))
  }
}

extension LiveActivityPanel where DoneAction == EmptyView {
  public init(
    _ presentation: ActivityPresentation, style: Style = .lockScreen, @ViewBuilder controls: () -> Controls
  ) {
    self.init(presentation, style: style, controls: controls) { EmptyView() }
  }
}

extension LiveActivityPanel where Controls == EmptyView, DoneAction == EmptyView {
  public init(_ presentation: ActivityPresentation, style: Style = .lockScreen) {
    self.init(presentation, style: style) {
      EmptyView()
    } doneAction: {
      EmptyView()
    }
  }
}

/// The phase glyph and its name: the leading side of the Lock Screen header and of the expanded island.
public struct ActivityPhaseTitle: View {
  private let presentation: ActivityPresentation
  private let onDark: Bool

  public init(_ presentation: ActivityPresentation, onDark: Bool) {
    self.presentation = presentation
    self.onDark = onDark
  }

  public var body: some View {
    HStack(spacing: Theme.Spacing.sm) {
      // The done card carries its own checkmark beside the headline.
      if presentation.phase != .done { IslandGlyph(phase: presentation.phase, onDark: onDark) }
      Text(verbatim: presentation.phaseTitle)
        .themeFont(.footnote, weight: .semibold)
        .foregroundStyle(onDark ? Color.white.opacity(0.85) : Theme.Ink.secondary)
    }
  }
}

/// The trailing side of the header: the running time while the memo is processed, the mode otherwise.
public struct ActivityHeaderTrailing: View {
  private let presentation: ActivityPresentation
  private let onDark: Bool

  public init(_ presentation: ActivityPresentation, onDark: Bool) {
    self.presentation = presentation
    self.onDark = onDark
  }

  public var body: some View {
    Group {
      if presentation.phase == .processing {
        ElapsedTimerText(start: presentation.start, frozenAt: presentation.timerFrozenAt)
      } else {
        Text(verbatim: presentation.modeLabel)
      }
    }
    .themeFont(.footnote, weight: .medium)
    .foregroundStyle(onDark ? Color.white.opacity(0.7) : Theme.Ink.muted)
    .multilineTextAlignment(.trailing)
  }
}
