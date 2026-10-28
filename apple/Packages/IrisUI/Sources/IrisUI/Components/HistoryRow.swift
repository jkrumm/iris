import SwiftUI

/// One History row (round 1): route chip and relative time on top, the headline, then the state line.
/// A done memo is dimmed and carries a check, a favorite carries a star. The List supplies the row background
/// (``HistoryRowBackground``).
public struct HistoryRow: View {
  private let routeLabel: String
  private let stateLabel: String
  private let stateColor: Color
  private let headline: String
  private let timeText: String
  private let isDone: Bool
  private let isFavorite: Bool

  public init(
    routeLabel: String,
    stateLabel: String,
    stateColor: Color,
    headline: String,
    timeText: String,
    isDone: Bool = false,
    isFavorite: Bool = false
  ) {
    self.routeLabel = routeLabel
    self.stateLabel = stateLabel
    self.stateColor = stateColor
    self.headline = headline
    self.timeText = timeText
    self.isDone = isDone
    self.isFavorite = isFavorite
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack {
        RouteChip(label: routeLabel, systemImage: "arrow.triangle.branch")
        Spacer()
        Text(verbatim: timeText)
          .themeFont(.caption)
          .foregroundStyle(Theme.Ink.muted)
      }
      Text(verbatim: headline)
        .themeFont(.subheadline, weight: .semibold)
        .foregroundStyle(Theme.Ink.primary)
        .lineLimit(2)
      HStack(spacing: Theme.Spacing.xs) {
        if isDone {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Theme.Status.good)
            .accessibilityHidden(true)
        }
        Text(verbatim: stateLabel)
          .foregroundStyle(stateColor)
        Spacer()
        if isFavorite {
          Image(systemName: "star.fill")
            .foregroundStyle(Theme.Status.warn)
            .accessibilityHidden(true)
        }
      }
      .themeFont(.caption, weight: .medium)
    }
    .opacity(isDone ? 0.55 : 1)
    .padding(.vertical, Theme.Spacing.xs)
    .accessibilityElement(children: .combine)
    .accessibilityValue(accessibilityValue)
  }

  private var accessibilityValue: String {
    var parts: [String] = []
    if isDone {
      parts.append(
        String(
          localized: "Marked done", bundle: #bundle, comment: "VoiceOver value of a History row the user marked done."))
    }
    if isFavorite {
      parts.append(
        String(localized: "Favorite", bundle: #bundle, comment: "VoiceOver value of a History row the user favorited."))
    }
    return parts.formatted()
  }
}

/// The List row background: the panel surface, tinted while the memo needs a route.
public struct HistoryRowBackground: View {
  private let needsAttention: Bool

  public init(needsAttention: Bool) {
    self.needsAttention = needsAttention
  }

  public var body: some View {
    Theme.Surface.panel
      .overlay { if needsAttention { Theme.Status.warn.opacity(0.12) } }
  }
}
