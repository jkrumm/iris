import SwiftUI

/// The full-width step waterfall: one row per step with its `duration · cost` chip, the faster/slower tag and the
/// attempt count where they apply, and a bar along the row's bottom edge that spans the card like a border. Steps
/// advancing animate subtly (none under Reduce Motion).
public struct StepWaterfall: View {
  private let rows: [StepWaterfallRow]
  private let totalTitle: String?
  private let totalValue: String?
  private let onRetry: (String) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// - Parameters:
  ///   - totalTitle: The footer's label ("Total"); the footer is drawn when both footer strings are set.
  ///   - onRetry: Called with the id of the row whose retry button was tapped.
  public init(
    rows: [StepWaterfallRow], totalTitle: String? = nil, totalValue: String? = nil,
    onRetry: @escaping (String) -> Void = { _ in }
  ) {
    self.rows = rows
    self.totalTitle = totalTitle
    self.totalValue = totalValue
    self.onRetry = onRetry
  }

  public var body: some View {
    VStack(spacing: 0) {
      ForEach(rows) { row in
        WaterfallRowView(row: row, onRetry: onRetry)
          .transition(.opacity)
      }
      if let totalTitle, let totalValue {
        HStack {
          Text(verbatim: totalTitle)
            .foregroundStyle(Theme.Ink.muted)
          Spacer()
          Text(verbatim: totalValue)
            .fontWeight(.semibold)
            .foregroundStyle(Theme.Ink.primary)
        }
        .themeFont(.subheadline)
        .monospacedDigit()
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .accessibilityElement(children: .combine)
      }
    }
    .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: rows)
    .detailCard()
  }
}

private struct WaterfallRowView: View {
  let row: StepWaterfallRow
  let onRetry: (String) -> Void

  private static let iconWidth: CGFloat = 22
  private static let trackHeight: CGFloat = 3

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
        PhaseIcon(phase: row.phase, isOptional: row.optionalNote != nil)
          .frame(width: Self.iconWidth)
        Text(verbatim: row.title)
          .themeFont(.subheadline, weight: .semibold)
          .foregroundStyle(titleColor)
        Spacer(minLength: Theme.Spacing.sm)
        metric
      }
      if row.badge != nil || row.attempts != nil || row.optionalNote != nil {
        ChipFlowLayout(spacing: Theme.Spacing.sm) {
          if let badge = row.badge { BadgeTag(badge: badge) }
          if let attempts = row.attempts {
            Text(verbatim: attempts)
              .themeFont(.caption, weight: .medium)
              .foregroundStyle(Theme.Status.warn)
          }
          if let note = row.optionalNote {
            Text(verbatim: note)
              .themeFont(.caption, weight: .medium)
              .foregroundStyle(Theme.Ink.secondary)
              .accessibilityIdentifier("detail.step.optional")
          }
        }
        .padding(.leading, Self.iconWidth + Theme.Spacing.sm)
      }
      if let error = row.error {
        Text(verbatim: error)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(failureColor)
          .padding(Theme.Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(failureColor.opacity(0.1), in: .rect(cornerRadius: Theme.Radius.control))
          .padding(.leading, Self.iconWidth + Theme.Spacing.sm)
      }
      if let retryTitle = row.retryTitle {
        Button {
          onRetry(row.id)
        } label: {
          Label(retryTitle, systemImage: "arrow.clockwise")
            .themeFont(.footnote, weight: .semibold)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(Theme.Accent.tint)
        .padding(.leading, Self.iconWidth + Theme.Spacing.sm)
        .accessibilityIdentifier("detail.step.retry")
      }
    }
    .padding(.horizontal, Theme.Spacing.lg)
    .padding(.top, Theme.Spacing.md)
    .padding(.bottom, Theme.Spacing.md + Self.trackHeight)
    .overlay(alignment: .bottom) { track }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("detail.step")
  }

  @ViewBuilder private var metric: some View {
    if let metric = row.metric {
      if row.phase == .waiting {
        Text(verbatim: metric)
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.faint)
      } else {
        Text(verbatim: metric)
          .themeFont(.footnote, weight: .medium)
          .monospacedDigit()
          .foregroundStyle(Theme.Ink.secondary)
          .padding(.horizontal, Theme.Spacing.sm)
          .padding(.vertical, Theme.Spacing.xs)
          .background(Theme.Surface.subtle, in: .capsule)
      }
    }
  }

  /// A failure the memo can live without is a warning; any other is the memo's failure.
  private var failureColor: Color {
    row.optionalNote == nil ? Theme.Status.bad : Theme.Status.warn
  }

  private var titleColor: Color {
    switch row.phase {
    case .waiting: Theme.Ink.faint
    case .failed: row.optionalNote == nil ? Theme.Status.bad : Theme.Ink.primary
    default: Theme.Ink.primary
    }
  }

  private var barColor: Color {
    switch row.phase {
    case .failed: failureColor
    case .running: Theme.Accent.tint.opacity(0.55)
    default: Theme.Accent.tint
    }
  }

  /// The bar along the row's bottom edge: the track is the whole run, the bar sits where the step ran.
  private var track: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Rectangle().fill(Theme.divider)
        if row.phase != .waiting {
          Rectangle()
            .fill(barColor)
            .frame(width: max(proxy.size.width * row.length, 2))
            .offset(x: proxy.size.width * row.start)
        }
      }
    }
    .frame(height: Self.trackHeight)
    .accessibilityHidden(true)
  }
}

private struct PhaseIcon: View {
  let phase: StepWaterfallRow.Phase
  var isOptional = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: 17))
      .foregroundStyle(color)
      .symbolEffect(.pulse, isActive: phase == .running && !reduceMotion)
      .contentTransition(.symbolEffect(.replace))
      .accessibilityLabel(label)
  }

  private var symbol: String {
    switch phase {
    case .waiting: "clock"
    case .running: "circle.dotted"
    case .done: "checkmark.circle.fill"
    case .failed: isOptional ? "exclamationmark.triangle.fill" : "xmark.circle.fill"
    }
  }

  private var color: Color {
    switch phase {
    case .waiting: Theme.Ink.faint
    case .running: Theme.Accent.tint
    case .done: Theme.Status.good
    case .failed: isOptional ? Theme.Status.warn : Theme.Status.bad
    }
  }

  private var label: Text {
    switch phase {
    case .waiting: Text("Waiting", bundle: #bundle, comment: "VoiceOver state of a step that has not started")
    case .running: Text("Running", bundle: #bundle, comment: "VoiceOver state of a step that is running")
    case .done: Text("Done", bundle: #bundle, comment: "VoiceOver state of a step that finished")
    case .failed: Text("Failed", bundle: #bundle, comment: "VoiceOver state of a step that failed")
    }
  }
}

private struct BadgeTag: View {
  let badge: StepWaterfallRow.Badge

  var body: some View {
    Text(verbatim: badge.text)
      .themeFont(.caption, weight: .semibold)
      .foregroundStyle(color)
      .padding(.horizontal, Theme.Spacing.sm)
      .padding(.vertical, 2)
      .background(color.opacity(0.14), in: .capsule)
  }

  private var color: Color {
    badge.tone == .slower ? Theme.Status.warn : Theme.Status.good
  }
}
