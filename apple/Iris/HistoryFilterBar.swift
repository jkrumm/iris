import IrisCore
import IrisUI
import SwiftUI

/// The quick-filter chips above the list: Favorites, Threads, Archived, then one chip per memo kind in the list.
struct HistoryFilterBar: View {
  @Binding var filters: HistoryFilters
  /// ``HistoryFilters/kinds(in:limit:)`` of the loaded memos.
  let kinds: [String]

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: Theme.Spacing.chipGap) {
        ForEach(QuickFilter.allCases, id: \.self) { filter in
          FilterChip(
            title: filter.title, systemImage: filter.systemImage, isOn: filters.quick == filter, size: .compact
          ) {
            withAnimation(.snappy) { filters.toggle(filter) }
          }
          .accessibilityIdentifier("history.chip.\(filter.identifier)")
        }
        ForEach(kinds, id: \.self) { kind in
          FilterChip(
            title: Memo.capitalizedKind(kind), dot: KindPalette.color(forKind: kind),
            isOn: filters.isSelected(kind: kind), size: .compact
          ) {
            withAnimation(.snappy) { filters.toggleKind(kind) }
          }
          .accessibilityIdentifier("history.chip.kind.\(kind)")
        }
      }
    }
    .contentMargins(.horizontal, Theme.Spacing.screenMargin, for: .scrollContent)
    .scrollIndicators(.hidden)
    .padding(.top, Theme.Spacing.chipRowTop - Theme.Spacing.chipTapOverhang)
  }
}

extension QuickFilter {
  var title: String {
    switch self {
    case .favorites: String(localized: "Favorites", comment: "Quick filter chip")
    case .threads: String(localized: "Threads", comment: "Quick filter chip")
    case .archived: String(localized: "Archived", comment: "Quick filter chip")
    }
  }

  var systemImage: String {
    switch self {
    case .favorites: "star"
    case .threads: "bubble.left"
    case .archived: "archivebox"
    }
  }

  fileprivate var identifier: String {
    switch self {
    case .favorites: "favorites"
    case .threads: "threads"
    case .archived: "archived"
    }
  }
}
