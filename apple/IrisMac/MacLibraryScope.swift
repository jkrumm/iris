import IrisCore

/// What the main window's sidebar can select. Each scope maps onto ``HistoryFilters``, the same filters the iPhone's History
/// uses, so the list, paging and event handling are the shared model's.
enum MacLibraryScope: Hashable, CaseIterable {
  case all
  case favorites
  case archive
  case threads

  /// Narrows `filters` to the scope and drops the previous scope's narrowing; the search text stays.
  func apply(to filters: inout HistoryFilters) {
    let search = filters.searchText
    filters.clear()
    filters.searchText = search
    switch self {
    case .all: break
    case .favorites: filters.toggle(.favorites)
    case .archive: filters.toggle(.archived)
    case .threads: filters.setThread(true)
    }
  }
}
