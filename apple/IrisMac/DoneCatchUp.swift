import Foundation
import IrisCore

/// Finds the memos that finished while the event stream was down. The stream has no replay: a `memo.done` during an outage is
/// never delivered, but the reload after the reconnect shows the memo done. This compares each list snapshot with the last one.
///
/// The first snapshot (the initial load) only sets the baseline and announces nothing, and so does the first snapshot after the
/// filters changed (a search shows memos that were done long ago). A memo counts as newly done when it was in the list in
/// another state, or when it is new to the list and changed after everything the last snapshot knew.
struct DoneCatchUp {
  private var known: [String: MemoState]?
  private var filters: HistoryFilters?
  private var newestUpdate = Date.distantPast

  mutating func newlyDone(in memos: [Memo], hasLoaded: Bool, filters current: HistoryFilters) -> [String] {
    guard hasLoaded else {
      self = DoneCatchUp()
      return []
    }
    defer {
      known = Dictionary(memos.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
      filters = current
      newestUpdate = max(newestUpdate, memos.map(\.updatedAt).max() ?? .distantPast)
    }
    guard let known, filters == current else { return [] }
    return memos.filter { memo in
      guard memo.state == .notified, !memo.isDeleted else { return false }
      if let before = known[memo.id] { return before != .notified }
      return memo.updatedAt > newestUpdate
    }.map(\.id)
  }
}

/// Counts the times the connection to the server came back (the link went live from anything else), so an open detail can
/// reload what it missed during the outage.
struct LinkTracker {
  private var last = ServerLink.unknown

  /// True when `link` is live and the last one was not.
  mutating func cameBack(_ link: ServerLink) -> Bool {
    defer { last = link }
    return link == .live && last != .live
  }
}
