import IrisCore

/// The chips above the list. One is active at a time; tapping it again clears it.
enum QuickFilter: CaseIterable, Hashable {
  case favorites
  case threads
  case archived
}

/// Everything that narrows the History list: a quick-filter chip, a memo kind, the filter sheet's state and the search
/// text. They combine; `query(cursor:)` is the one place that turns them into `GET /v1/memos` parameters.
struct HistoryFilters: Hashable {
  static let pageSize = 50
  /// How many kind chips the quick row shows.
  static let kindChipLimit = 5

  private(set) var quick: QuickFilter?
  /// The memo kind the list is narrowed to (Hermes' free-form label, compared case-insensitively).
  private(set) var kind: String?
  private(set) var state: MemoState?
  /// Narrows to the memos in a thread besides the Threads chip: the Mac sidebar's Threads. Never set on the iPhone.
  private(set) var thread = false
  var searchText = ""

  /// How many sheet filters are on, for the badge on the filter button.
  var sheetFilterCount: Int { (kind == nil ? 0 : 1) + (state == nil ? 0 : 1) }

  var isFiltering: Bool { quick != nil || thread || sheetFilterCount > 0 || trimmedSearch != nil }

  /// The server alone can decide membership: a thread and `q` are not on the wire memo.
  var needsServerMatching: Bool { quick == .threads || thread || trimmedSearch != nil }

  private var trimmedSearch: String? {
    let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  mutating func toggle(_ filter: QuickFilter) {
    quick = quick == filter ? nil : filter
  }

  mutating func setThread(_ narrowed: Bool) {
    thread = narrowed
  }

  mutating func toggleKind(_ newKind: String) {
    kind = isSelected(kind: newKind) ? nil : newKind
  }

  func isSelected(kind candidate: String) -> Bool {
    kind?.lowercased() == candidate.lowercased()
  }

  mutating func toggleState(_ newState: MemoState) {
    state = state == newState ? nil : newState
  }

  /// Clears the sheet's filters; the chip and the search stay.
  mutating func resetSheet() {
    kind = nil
    state = nil
  }

  mutating func clear() {
    self = HistoryFilters()
  }

  func query(cursor: String? = nil) -> ListMemosQuery {
    ListMemosQuery(
      limit: Self.pageSize, cursor: cursor, q: trimmedSearch, state: state,
      favorite: quick == .favorites, archived: quick == .archived, kind: kind, thread: quick == .threads || thread)
  }

  /// The flag, kind and state half of the filter, for a memo the client already holds (an SSE update, an
  /// optimistic flag change). It cannot tell `q` or a thread; see `needsServerMatching`.
  func matches(_ memo: Memo) -> Bool {
    guard !memo.isDeleted, memo.archived == (quick == .archived) else { return false }
    if quick == .favorites, !memo.favorite { return false }
    if let kind, memo.kind?.lowercased() != kind.lowercased() { return false }
    if let state, memo.state != state { return false }
    return true
  }

  // MARK: Kinds

  /// The distinct kinds of `memos` (case-insensitive, lower-cased), most frequent first, then by name; at most `limit`.
  /// The selected kind is always in the answer, even when it is not in `memos` (the list is narrowed to it, or it dropped out).
  func kinds(in memos: [Memo], limit: Int? = nil) -> [String] {
    var counts: [String: Int] = [:]
    for memo in memos where memo.hasKind {
      guard let kind = memo.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { continue }
      counts[kind, default: 0] += 1
    }
    var ranked = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map(\.key)
    if let limit { ranked = Array(ranked.prefix(limit)) }
    guard let selected = kind?.lowercased(), !ranked.contains(selected) else { return ranked }
    if let limit, ranked.count >= limit { ranked.removeLast() }
    return ranked + [selected]
  }
}
