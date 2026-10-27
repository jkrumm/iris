import IrisCore
import IrisUI
import SwiftUI
import WidgetKit

/// Placeholder Live Activity. The contract has no recording phase yet, so `.processing` is the one in-flight
/// phase: it shows the running timer from `startedAt`; the others show the result.
struct MemoLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: MemoAttributes.self) { context in
      LockScreenView(attributes: context.attributes, state: context.state)
        .padding(Theme.Spacing.lg)
        .activityBackgroundTint(Theme.Surface.panel)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          PhaseLabel(phase: context.state.phase)
        }
        DynamicIslandExpandedRegion(.trailing) {
          ElapsedTimer(attributes: context.attributes, state: context.state)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(context.state.headline ?? "")
            .themeFont(.footnote)
            .lineLimit(2)
        }
      } compactLeading: {
        Image(systemName: context.state.phase.symbol)
          .accessibilityHidden(true)
      } compactTrailing: {
        ElapsedTimer(attributes: context.attributes, state: context.state)
          .frame(maxWidth: 52)
      } minimal: {
        Image(systemName: context.state.phase.symbol)
          .accessibilityHidden(true)
      }
    }
  }
}

private struct LockScreenView: View {
  let attributes: MemoAttributes
  let state: LiveActivityContentState

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack {
        PhaseLabel(phase: state.phase)
        Spacer()
        ElapsedTimer(attributes: attributes, state: state)
      }
      if let routeChip = state.routeChip {
        RouteChip(label: routeChip, systemImage: "arrow.triangle.branch")
      }
      if let headline = state.headline {
        Text(headline)
          .themeFont(.subheadline, weight: .semibold)
          .foregroundStyle(Theme.Ink.primary)
          .lineLimit(2)
      }
    }
  }
}

private struct PhaseLabel: View {
  let phase: LiveActivityPhase

  var body: some View {
    Label(phase.title, systemImage: phase.symbol)
      .themeFont(.footnote, weight: .medium)
      .foregroundStyle(Theme.Ink.secondary)
  }
}

/// Counts up from `startedAt` while the take is in flight; hidden otherwise.
private struct ElapsedTimer: View {
  let attributes: MemoAttributes
  let state: LiveActivityContentState

  var body: some View {
    if state.phase == .processing {
      Text(timerInterval: attributes.startedAt...Date.distantFuture, countsDown: false)
        .themeFont(.footnote, weight: .medium)
        .monospacedDigit()
        .contentTransition(.numericText())
        .multilineTextAlignment(.trailing)
        .foregroundStyle(Theme.Accent.tint)
    }
  }
}

extension LiveActivityPhase {
  fileprivate var title: String {
    switch self {
    case .processing: String(localized: "Processing", comment: "Live Activity phase")
    case .needsRoute: String(localized: "Needs a route", comment: "Live Activity phase")
    case .done: String(localized: "Done", comment: "Live Activity phase")
    case .failed: String(localized: "Failed", comment: "Live Activity phase")
    }
  }

  fileprivate var symbol: String {
    switch self {
    case .processing: "waveform"
    case .needsRoute: "arrow.triangle.branch"
    case .done: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    }
  }
}
