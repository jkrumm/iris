import SwiftUI

/// The status line of a History row (round 2 render): what the memo is doing or where it went.
public enum HistoryRowStatus: Equatable {
  /// A routed memo: `● Route · duration`.
  case settled(route: String, dot: Color, duration: String?)
  /// The pipeline is still driving it: `● Route · Acting`.
  case inFlight(route: String, dot: Color, label: String)
  /// Needs the user (Needs route, Failed): the coloured state replaces the route.
  case alert(label: String, color: Color)
}

/// One History row: the status line with the time right-aligned, the headline, and one grey secondary line.
/// A done memo is dimmed and carries a check, a favorite carries a star. Plain list row: the List supplies the
/// separators and ``HistoryRowBackground``.
public struct HistoryRow: View {
  private let status: HistoryRowStatus
  private let headline: String
  private let secondary: String?
  private let timeText: String
  private let isDone: Bool
  private let isFavorite: Bool

  public init(
    status: HistoryRowStatus,
    headline: String,
    secondary: String? = nil,
    timeText: String,
    isDone: Bool = false,
    isFavorite: Bool = false
  ) {
    self.status = status
    self.headline = headline
    self.secondary = secondary
    self.timeText = timeText
    self.isDone = isDone
    self.isFavorite = isFavorite
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
        statusLine
        Spacer(minLength: Theme.Spacing.sm)
        if isFavorite {
          Image(systemName: "star.fill")
            .foregroundStyle(Theme.Status.warn)
            .accessibilityHidden(true)
        }
        if isDone {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(Theme.Status.good)
            .accessibilityHidden(true)
        }
        Text(verbatim: timeText)
          .foregroundStyle(Theme.Ink.faint)
      }
      .themeFont(.caption)
      Text(verbatim: headline)
        .themeFont(.callout, weight: .semibold)
        .foregroundStyle(Theme.Ink.primary)
        .lineLimit(2)
      if let secondary {
        Text(verbatim: secondary)
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.muted)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .opacity(isDone ? 0.55 : 1)
    .padding(.vertical, Theme.Spacing.sm)
    .accessibilityElement(children: .combine)
    .accessibilityValue(accessibilityValue)
  }

  @ViewBuilder private var statusLine: some View {
    switch status {
    case .settled(let route, let dot, let duration):
      HStack(spacing: Theme.Spacing.sm) {
        Dot(color: dot)
        Text(verbatim: route)
          .fontWeight(.semibold)
          .foregroundStyle(Theme.Ink.secondary)
        if let duration {
          Text(verbatim: "·")
          Text(verbatim: duration)
        }
      }
      .foregroundStyle(Theme.Ink.muted)
    case .inFlight(let route, let dot, let label):
      HStack(spacing: Theme.Spacing.sm) {
        Dot(color: dot)
        Text(verbatim: route)
          .fontWeight(.semibold)
          .foregroundStyle(Theme.Ink.secondary)
        Text(verbatim: "·")
          .foregroundStyle(Theme.Ink.muted)
        Text(verbatim: label)
          .fontWeight(.semibold)
          .foregroundStyle(Theme.Accent.tint)
      }
    case .alert(let label, let color):
      HStack(spacing: Theme.Spacing.sm) {
        Dot(color: color)
        Text(verbatim: label)
          .fontWeight(.semibold)
          .foregroundStyle(color)
      }
    }
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
        String(
          localized: "Favorite", bundle: #bundle, comment: "VoiceOver value of a History row the user favorited."))
    }
    return parts.formatted()
  }
}

private struct Dot: View {
  let color: Color

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 8, height: 8)
      .accessibilityHidden(true)
  }
}

/// The List row background: the page surface, tinted while the memo needs a route.
public struct HistoryRowBackground: View {
  private let needsAttention: Bool

  public init(needsAttention: Bool) {
    self.needsAttention = needsAttention
  }

  public var body: some View {
    Theme.Surface.background
      .overlay { if needsAttention { Theme.Status.warn.opacity(0.1) } }
  }
}
