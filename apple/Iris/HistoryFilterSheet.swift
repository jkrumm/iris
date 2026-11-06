import IrisCore
import IrisUI
import SwiftUI

/// How many memos the list holds once the sheet closes, when the app can say. The list wire has no total, so the count is
/// exact only when the whole result fits the first page (fewer rows than a page) and the load has
/// settled; otherwise the button names no number rather than a wrong one.
enum HistoryResultCount {
  static func exact(memos: Int, isSettled: Bool) -> Int? {
    isSettled && memos < HistoryFilters.pageSize ? memos : nil
  }

  static func buttonTitle(_ count: Int?) -> String {
    switch count {
    case nil: String(localized: "Show memos", comment: "Closes the filter sheet")
    case 1?: String(localized: "Show 1 memo", comment: "Closes the filter sheet; one memo matches")
    case let count?:
      String(localized: "Show \(count) memos", comment: "Closes the filter sheet; the number of memos that match")
    }
  }
}

/// The bottom sheet: the view (Favorites, Threads, Archived), kind and state, applied live. The search stays as it is.
struct HistoryFilterSheet: View {
  @Binding var filters: HistoryFilters
  /// ``HistoryResultCount/exact(memos:isSettled:)`` of the list behind the sheet.
  let resultCount: Int?
  /// ``HistoryFilters/kinds(in:limit:)`` of the loaded memos, uncapped.
  let kinds: [String]
  @Environment(\.dismiss) private var dismiss
  @State private var contentHeight: CGFloat = 340

  private static let states: [MemoState] = [.failed, .notified]

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      HStack(alignment: .firstTextBaseline) {
        Text("Filter", comment: "Title of the filter sheet")
          .themeFont(.title3, weight: .semibold)
          .foregroundStyle(Theme.Ink.primary)
        Spacer()
        Button(String(localized: "Reset", comment: "Clears the sheet filters")) {
          withAnimation(.snappy) { filters.resetFilters() }
        }
        .disabled(filters.activeFilterCount == 0)
        .accessibilityIdentifier("history.filter.reset")
      }
      group(String(localized: "View", comment: "Filter sheet group: Favorites, Threads, Archived")) {
        ForEach(QuickFilter.allCases, id: \.self) { filter in
          FilterChip(
            title: filter.title, systemImage: filter.systemImage, isOn: filters.quick == filter, size: .regular
          ) {
            withAnimation(.snappy) { filters.toggle(filter) }
          }
          .accessibilityIdentifier("history.filter.quick.\(filter.identifier)")
        }
      }
      if !kinds.isEmpty {
        group(String(localized: "Kind", comment: "Filter sheet group")) {
          ForEach(kinds, id: \.self) { kind in
            FilterChip(
              title: Memo.capitalizedKind(kind), dot: KindPalette.color(forKind: kind),
              isOn: filters.isSelected(kind: kind), size: .regular
            ) {
              withAnimation(.snappy) { filters.toggleKind(kind) }
            }
            .accessibilityIdentifier("history.filter.kind.\(kind)")
          }
        }
      }
      group(String(localized: "State", comment: "Filter sheet group")) {
        ForEach(Self.states, id: \.self) { state in
          FilterChip(title: state.label, dot: state.color, isOn: filters.state == state, size: .regular) {
            withAnimation(.snappy) { filters.toggleState(state) }
          }
        }
      }
      Button {
        dismiss()
      } label: {
        Text(verbatim: HistoryResultCount.buttonTitle(resultCount))
          .frame(maxWidth: .infinity)
          .contentTransition(.numericText())
      }
      .buttonStyle(.primary)
      .controlSize(.large)
      .padding(.top, Theme.Spacing.sheetInset - Theme.Spacing.md)
      .accessibilityIdentifier("history.filter.show")
    }
    .padding(.horizontal, Theme.Spacing.sheetInset)
    .padding(.top, Theme.Spacing.cozy)
    .padding(.bottom, Theme.Spacing.sheetInset)
    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
    // The sheet is as tall as its content: no empty panel under the button.
    .presentationDetents([.height(max(contentHeight, Theme.Spacing.tapTarget))])
    .accessibilityIdentifier("history.filter.sheet")
  }

  private func group(_ title: String, @ViewBuilder chips: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      Text(title)
        .themeFont(.caption, weight: .semibold)
        .foregroundStyle(Theme.Ink.muted)
        .textCase(.uppercase)
      // The 36 pt chips answer taps over 44 pt, so the drawn rows keep their 8 pt gap with none between the areas.
      ChipFlowLayout(lineSpacing: Theme.Spacing.sm - (Theme.Spacing.tapTarget - Theme.Spacing.chipHeightLarge)) {
        chips()
      }
    }
  }
}
