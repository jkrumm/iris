import SwiftUI

/// The step waterfall: collapsed it is one line, "Total · duration · cost", and a tap on it opens the steps. Expanded,
/// one row per step with its `duration · cost` chip, the faster/slower tag and the attempt count where they apply, and
/// a bar along the row's bottom edge that spans the card like a border. Steps advancing animate subtly (none under
/// Reduce Motion). Without a total there is nothing to collapse to, so the rows show.
public struct StepWaterfall: View {
  private let rows: [StepWaterfallRow]
  private let totalTitle: String?
  private let totalValue: String?
  private let isExpanded: Binding<Bool>
  private let onRetry: (String) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// - Parameters:
  ///   - totalTitle: The summary line's label ("Total"); the line is drawn when both strings are set.
  ///   - isExpanded: Whether the steps show under the summary line.
  ///   - onRetry: Called with the id of the row whose retry button was tapped.
  public init(
    rows: [StepWaterfallRow], totalTitle: String? = nil, totalValue: String? = nil, isExpanded: Binding<Bool>,
    onRetry: @escaping (String) -> Void = { _ in }
  ) {
    self.rows = rows
    self.totalTitle = totalTitle
    self.totalValue = totalValue
    self.isExpanded = isExpanded
    self.onRetry = onRetry
  }

  public var body: some View {
    VStack(spacing: 0) {
      if let totalTitle, let totalValue {
        summary(title: totalTitle, value: totalValue)
      }
      if showsRows {
        ForEach(rows) { row in
          WaterfallRowView(row: row, onRetry: onRetry)
            .transition(.opacity)
        }
      }
    }
    .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: rows)
    .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: showsRows)
    .detailCard()
  }

  private var hasSummary: Bool { totalTitle != nil && totalValue != nil }
  private var showsRows: Bool { !hasSummary || isExpanded.wrappedValue }

  private func summary(title: String, value: String) -> some View {
    Button {
      isExpanded.wrappedValue.toggle()
    } label: {
      HStack(spacing: Theme.Spacing.sm) {
        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(Theme.Ink.muted)
          .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
          .frame(width: 22)
        Text(verbatim: title)
          .foregroundStyle(Theme.Ink.muted)
        Spacer(minLength: Theme.Spacing.sm)
        Text(verbatim: value)
          .fontWeight(.semibold)
          .foregroundStyle(Theme.Ink.primary)
      }
      .themeFont(.subheadline)
      .monospacedDigit()
      .padding(.horizontal, Theme.Spacing.cardInsetHorizontal)
      .padding(.vertical, Theme.Spacing.cardInsetVertical)
      .frame(maxWidth: .infinity)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityValue(
      isExpanded.wrappedValue
        ? Text("Expanded", bundle: #bundle, comment: "VoiceOver state of the step summary when the steps show")
        : Text("Collapsed", bundle: #bundle, comment: "VoiceOver state of the step summary when the steps are hidden")
    )
    .accessibilityHint(
      Text("Shows or hides the steps", bundle: #bundle, comment: "VoiceOver hint of the step summary line")
    )
    .accessibilityIdentifier("detail.steps.toggle")
  }
}

private struct WaterfallRowView: View {
  let row: StepWaterfallRow
  let onRetry: (String) -> Void

  private static let iconWidth: CGFloat = 22
  private static let trackHeight: CGFloat = 3
  private static let minimumBar: CGFloat = 2

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
        PhaseIcon(phase: row.phase, isOptional: row.isOptional)
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
    .padding(.horizontal, Theme.Spacing.cardInsetHorizontal)
    .padding(.top, Theme.Spacing.cardInsetVertical)
    .padding(.bottom, Theme.Spacing.cardInsetVertical + Self.trackHeight)
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
    row.isOptional ? Theme.Status.warn : Theme.Status.bad
  }

  private var titleColor: Color {
    switch row.phase {
    case .waiting: Theme.Ink.faint
    case .failed: row.isOptional ? Theme.Ink.primary : Theme.Status.bad
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

  /// The bar along the row's bottom edge: the track is the whole run, the bar sits where the step ran. A bar never
  /// reaches past the track, and a very short step keeps a two-point sliver.
  private var track: some View {
    GeometryReader { proxy in
      let width = max(proxy.size.width * row.length, Self.minimumBar)
      ZStack(alignment: .leading) {
        Rectangle().fill(Theme.divider)
        if row.phase != .waiting {
          Rectangle()
            .fill(barColor)
            .frame(width: width)
            .offset(x: min(proxy.size.width * row.start, proxy.size.width - width))
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
      .padding(.vertical, Theme.Spacing.hair)
      .background(color.opacity(0.14), in: .capsule)
  }

  private var color: Color {
    badge.tone == .slower ? Theme.Status.warn : Theme.Status.good
  }
}
