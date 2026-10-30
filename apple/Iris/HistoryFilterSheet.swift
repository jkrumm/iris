import IrisCore
import IrisUI
import SwiftUI

/// The bottom sheet (round 2): route and state, applied live. Search and the quick chips stay as they are.
struct HistoryFilterSheet: View {
  @Binding var filters: HistoryFilters
  @Environment(\.dismiss) private var dismiss

  private static let states: [MemoState] = [.needsRoute, .failed, .notified]

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      HStack(alignment: .firstTextBaseline) {
        Text("Filter", comment: "Title of the filter sheet")
          .themeFont(.title3, weight: .semibold)
          .foregroundStyle(Theme.Ink.primary)
        Spacer()
        Button(String(localized: "Reset", comment: "Clears the sheet filters")) {
          withAnimation(.snappy) { filters.resetSheet() }
        }
        .disabled(filters.sheetFilterCount == 0)
        .accessibilityIdentifier("history.filter.reset")
      }
      group(String(localized: "Route", comment: "Filter sheet group")) {
        ForEach(RouteDestination.allCases, id: \.self) { destination in
          FilterChip(title: destination.title, isOn: filters.route == destination, size: .regular) {
            withAnimation(.snappy) { filters.toggleRoute(destination) }
          }
        }
      }
      group(String(localized: "State", comment: "Filter sheet group")) {
        ForEach(Self.states, id: \.self) { state in
          FilterChip(title: state.label, isOn: filters.effectiveState == state, size: .regular) {
            withAnimation(.snappy) { filters.toggleState(state) }
          }
        }
      }
      Button {
        dismiss()
      } label: {
        Text("Show memos", comment: "Closes the filter sheet")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.glassProminent)
      .controlSize(.large)
      .padding(.top, Theme.Spacing.sheetInset - Theme.Spacing.md)
      .accessibilityIdentifier("history.filter.show")
    }
    .padding(.horizontal, Theme.Spacing.sheetInset)
    .padding(.top, Theme.Spacing.cozy)
    .frame(maxHeight: .infinity, alignment: .top)
    .accessibilityIdentifier("history.filter.sheet")
  }

  private func group(_ title: String, @ViewBuilder chips: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      Text(title)
        .themeFont(.caption, weight: .semibold)
        .foregroundStyle(Theme.Ink.muted)
        .textCase(.uppercase)
      ChipFlowLayout { chips() }
    }
  }
}

extension RouteDestination {
  var title: String {
    switch self {
    case .hermes: String(localized: "Hermes", comment: "Route name")
    case .journal: String(localized: "Journal", comment: "Route name")
    case .herdr: String(localized: "Tabs", comment: "Route name for memos sent to a herdr tab")
    }
  }
}
