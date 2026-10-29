import SwiftUI

/// The compact banner a take continues as while the user browses: a record dot, the running time, what is recording, and
/// a Stop. The whole banner opens the full take screen.
public struct TakeBanner: View {
  private let isPaused: Bool
  private let start: Date
  private let frozenAt: Date?
  private let title: String
  private let detail: String?
  private let stopLabel: String
  private let openHint: String
  private let onOpen: () -> Void
  private let onStop: () -> Void

  /// - Parameters:
  ///   - start: the instant the timer counts from (the take's start, moved forward by what was paused).
  ///   - frozenAt: stops the timer at this instant (a paused take, the snapshot tests).
  public init(
    isPaused: Bool, start: Date, frozenAt: Date? = nil, title: String, detail: String? = nil, stopLabel: String,
    openHint: String, onOpen: @escaping () -> Void, onStop: @escaping () -> Void
  ) {
    self.isPaused = isPaused
    self.start = start
    self.frozenAt = frozenAt
    self.title = title
    self.detail = detail
    self.stopLabel = stopLabel
    self.openHint = openHint
    self.onOpen = onOpen
    self.onStop = onStop
  }

  public var body: some View {
    HStack(spacing: Theme.Spacing.sm) {
      Button(action: onOpen) {
        HStack(spacing: Theme.Spacing.sm) {
          Image(systemName: isPaused ? "pause.fill" : "circle.fill")
            .font(.system(size: isPaused ? 12 : 9, weight: .bold))
            .foregroundStyle(isPaused ? Theme.Ink.muted : Theme.Status.bad)
            .frame(width: 14)
            .accessibilityHidden(true)
          ElapsedTimerText(start: start, frozenAt: frozenAt)
            .themeFont(.subheadline, weight: .semibold)
            .foregroundStyle(Theme.Ink.primary)
          VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title)
              .themeFont(.footnote, weight: .medium)
              .foregroundStyle(Theme.Ink.secondary)
              .lineLimit(1)
            if let detail {
              Text(verbatim: detail)
                .themeFont(.caption)
                .foregroundStyle(Theme.Ink.muted)
                .lineLimit(1)
            }
          }
          Spacer(minLength: Theme.Spacing.sm)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityHint(openHint)
      .accessibilityIdentifier("take.banner.open")

      Button(action: onStop) {
        Image(systemName: "stop.fill")
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(Theme.Accent.onFill)
          .frame(width: 34, height: 34)
          .background(Theme.Status.bad, in: .circle)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(stopLabel)
      .accessibilityIdentifier("take.banner.stop")
    }
    .padding(.leading, Theme.Spacing.lg)
    .padding(.trailing, Theme.Spacing.sm)
    .padding(.vertical, Theme.Spacing.sm)
    .glassEffect(.regular, in: .capsule)
    .accessibilityElement(children: .contain)
  }
}
