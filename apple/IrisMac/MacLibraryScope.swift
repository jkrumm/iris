import IrisCore

/// What the main window's sidebar can select. Each scope maps onto ``HistoryFilters``, the same filters the iPhone's History
/// uses, so the list, paging and event handling are the shared model's.
enum MacLibraryScope: Hashable, CaseIterable {
  case all
  case favorites
  case archive
  case threads

  /// Narrows `filters` to the scope and drops the previous scope's narrowing; the search text, the kind and the state stay (they
  /// are the sidebar's filter, not part of the scope).
  func apply(to filters: inout HistoryFilters) {
    let search = filters.searchText
    let kind = filters.kind
    let state = filters.state
    filters.clear()
    filters.searchText = search
    if let kind { filters.toggleKind(kind) }
    if let state { filters.toggleState(state) }
    switch self {
    case .all: break
    case .favorites: filters.toggle(.favorites)
    case .archive: filters.toggle(.archived)
    case .threads: filters.setThread(true)
    }
  }
}

extension HistoryFilters {
  /// The sidebar's filter is on: a kind or a state narrows the list.
  var hasKindOrState: Bool { kind != nil || state != nil }

  /// The sidebar's one-click clear: the kind and the state go, the scope and the search stay.
  mutating func clearKindAndState() {
    if let kind { toggleKind(kind) }
    if let state { toggleState(state) }
  }
}
