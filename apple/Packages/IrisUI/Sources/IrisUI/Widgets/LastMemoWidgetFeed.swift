import Foundation

/// A memo as the feed needs to see it, with no dependency on the app's model types: the app maps its `Memo` onto this.
public struct WidgetMemoObservation: Equatable, Sendable {
  public var id: String
  public var createdAt: Date
  public var phase: LastMemoSnapshot.Phase
  /// Where the memo went; `nil` before it is routed (the mode is not a route).
  public var routeChip: String?
  /// The server's summary headline. Never a transcript clip.
  public var headline: String?
  /// Soft-deleted (the undo window): not the last memo any more.
  public var isDeleted: Bool

  public init(
    id: String, createdAt: Date, phase: LastMemoSnapshot.Phase, routeChip: String? = nil, headline: String? = nil,
    isDeleted: Bool = false
  ) {
    self.id = id
    self.createdAt = createdAt
    self.phase = phase
    self.routeChip = routeChip
    self.headline = headline
    self.isDeleted = isDeleted
  }
}

/// The app's side of the widget data path: keeps the snapshot equal to the newest memo and asks WidgetKit for a new
/// timeline when what a widget would show changed. Memos arrive from History (the event stream and list loads) in any order, so
/// only a memo that is not older than the stored one replaces it, and a repeated state costs no reload.
@MainActor
public final class LastMemoWidgetFeed {
  private let store: any LastMemoSnapshotStoring
  private let reload: @MainActor () -> Void
  private let now: @MainActor () -> Date
  private var current: LastMemoSnapshot?
  /// Memos the app hid or purged (``forget(id:)``): a late event for one of them must not bring it back.
  private var forgotten: Set<String> = []

  /// `reload` is `WidgetCenter.shared.reloadTimelines(ofKind:)` in the app (IrisUI does not link WidgetKit).
  public init(
    store: any LastMemoSnapshotStoring, reload: @escaping @MainActor () -> Void,
    now: @escaping @MainActor () -> Date = { Date() }
  ) {
    self.store = store
    self.reload = reload
    self.now = now
    current = store.load()
  }

  /// A memo appeared or changed.
  public func observe(_ memo: WidgetMemoObservation) {
    guard !forgotten.contains(memo.id) else { return }
    if memo.isDeleted {
      // Soft-deleted: gone for now, and back with the next observation if the user undoes it.
      clear(id: memo.id)
      return
    }
    if let current, current.memoID != memo.id, memo.createdAt < current.createdAt { return }
    let next = LastMemoSnapshot(
      memoID: memo.id, createdAt: memo.createdAt, phase: memo.phase, routeChip: memo.routeChip,
      headline: memo.headline, updatedAt: now())
    if let current, current.showsSameAs(next) {
      // Nothing a widget shows changed. An in-flight memo is still running, though: restamp it, or the timeline's idle
      // entry (at the old stamp + `staleAfter`) turns the widget to "Ready" while the app shows it processing. A
      // settled state keeps its first stamp, so its age stays true.
      if !current.phase.isSettled { write(next) }
      return
    }
    write(next)
  }

  /// A memo is gone for good (hidden, purged): if it was the one shown, the widget goes back to its static state, and no
  /// later event for the id brings it back.
  public func forget(id: String) {
    forgotten.insert(id)
    clear(id: id)
  }

  /// The connection changed: the stored memo belongs to the server the app just left, so the widget goes back to its static
  /// state and nothing remembered about the old server (the forgotten ids) applies to the new one.
  public func reset() {
    forgotten = []
    guard current != nil else { return }
    write(nil)
  }

  private func clear(id: String) {
    guard current?.memoID == id else { return }
    write(nil)
  }

  private func write(_ snapshot: LastMemoSnapshot?) {
    guard store.save(snapshot) else { return }
    current = snapshot
    reload()
  }
}
