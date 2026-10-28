import Foundation
import IrisCore
import Observation
import os

/// The memo list behind History (and, via `load()` and `memos`, the Mac menu bar panel): paging, filters, SSE
/// updates and the optimistic flag actions, all through an `APIClient`.
@Observable
final class HistoryModel {
  /// Open `needs_route` memos, newest first. They sit above `items` and are never paged.
  private(set) var pinned: [Memo] = []
  private(set) var items: [Memo] = []
  private(set) var loadFailed = false
  private(set) var hasLoaded = false
  private(set) var toast: HistoryToast?
  var filters = HistoryFilters()

  var memos: [Memo] { pinned + items }

  private let client: any APIClient
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "history")
  private var nextCursor: String?
  private var isLoadingMore = false
  /// Bumped by every first-page load; a response that finds it changed belongs to filters that are gone.
  private var generation = 0

  init(client: any APIClient) {
    self.client = client
  }

  // MARK: Loading

  /// Loads the first page for the current filters. Pull to refresh, a filter change and an SSE reconnect all land here.
  func load() async {
    generation += 1
    let current = generation
    do {
      let page = try await client.listMemos(filters.query())
      guard current == generation else { return }
      // A memo answered after the first page can repeat across pinned and items: pinned first, then the new ids.
      let pinnedIDs = Set(page.pinned.map(\.id))
      pinned = page.pinned
      items = page.items.filter { !pinnedIDs.contains($0.id) }
      nextCursor = page.nextCursor
      loadFailed = false
      hasLoaded = true
    } catch is CancellationError {
      return
    } catch {
      guard current == generation else { return }
      logger.error("history load failed: \(String(describing: error), privacy: .public)")
      loadFailed = true
    }
  }

  /// Fetches the next page when `memo` is the last row on screen.
  func loadMoreIfNeeded(current memo: Memo) async {
    guard let cursor = nextCursor, !isLoadingMore, memo.id == items.last?.id else { return }
    isLoadingMore = true
    defer { isLoadingMore = false }
    let loading = generation
    do {
      let page = try await client.listMemos(filters.query(cursor: cursor))
      guard loading == generation else { return }
      let known = Set(memos.map(\.id))
      items += page.items.filter { !known.contains($0.id) }
      nextCursor = page.nextCursor
    } catch is CancellationError {
      return
    } catch {
      logger.error("history page failed: \(String(describing: error), privacy: .public)")
    }
  }

  // MARK: Live updates

  /// Follows `GET /v1/events` until cancelled, reconnecting after a drop. The stream has no replay, so every
  /// (re)connect refetches the list.
  func observeEvents() async {
    while !Task.isCancelled {
      do {
        for try await event in client.events() {
          await handle(event)
        }
      } catch {
        logger.error("history events dropped: \(String(describing: error), privacy: .public)")
      }
      guard (try? await Task.sleep(for: .seconds(3))) != nil else { return }
    }
  }

  func handle(_ event: ServerEvent) async {
    switch event {
    case .ready:
      await load()
    case .memoUpdated(let update):
      await refresh(id: update.id)
    case .memoDone:
      // Always follows a `memo.updated` for the same state.
      break
    }
  }

  /// The event carries the state only, so the flags come from the memo itself.
  private func refresh(id: String) async {
    if filters.needsServerMatching, !memos.contains(where: { $0.id == id }) {
      await load()
      return
    }
    do {
      place(try await client.memo(id: id).memo)
    } catch let error as APIError {
      if case .server(404, _) = error {
        remove(id)
      } else {
        logger.error("history refresh failed: \(String(describing: error), privacy: .public)")
      }
    } catch {
      return
    }
  }

  // MARK: Actions

  func toggleDone(_ memo: Memo) async {
    await update(memo, done: !memo.done)
  }

  func toggleFavorite(_ memo: Memo) async {
    await update(memo, favorite: !memo.favorite)
  }

  /// Leaves the list unless the Archived filter is on and the memo was already archived.
  func toggleArchived(_ memo: Memo) async {
    await update(memo, archived: !memo.archived)
  }

  /// Removes the row at once; the toast offers the undo for as long as the server keeps the memo.
  func delete(_ memo: Memo) async {
    guard let before = held(memo.id), before.state.isDeletable else { return }
    remove(before.id)
    do {
      let deleted = try await client.deleteMemo(id: before.id)
      toast = HistoryToast(
        kind: .undoDelete(memoID: deleted.id),
        message: String(localized: "Memo deleted", comment: "Toast after a swipe delete"))
    } catch is CancellationError {
      place(before, force: true)
    } catch {
      place(before, force: true)
      show(error: String(localized: "Could not delete the memo", comment: "Toast when a delete failed"), cause: error)
    }
  }

  func undoDelete() async {
    guard case .undoDelete(let id)? = toast?.kind else { return }
    toast = nil
    do {
      place(try await client.restoreMemo(id: id), force: true)
    } catch is CancellationError {
      return
    } catch {
      show(error: String(localized: "Could not restore the memo", comment: "Toast when an undo failed"), cause: error)
    }
  }

  func dismissToast(id: HistoryToast.ID) {
    if toast?.id == id { toast = nil }
  }

  /// Applies the flags to the row first and rolls it back (position included) when the server refuses.
  private func update(_ memo: Memo, done: Bool? = nil, favorite: Bool? = nil, archived: Bool? = nil) async {
    guard let before = held(memo.id) else { return }
    var after = before
    after.done = done ?? after.done
    after.favorite = favorite ?? after.favorite
    after.archived = archived ?? after.archived
    place(after, force: true)
    do {
      place(try await client.setFlags(id: before.id, done: done, favorite: favorite, archived: archived), force: true)
    } catch is CancellationError {
      place(before, force: true)
    } catch {
      place(before, force: true)
      show(
        error: String(localized: "Could not update the memo", comment: "Toast when a flag change failed"), cause: error)
    }
  }

  private func show(error message: String, cause: any Error) {
    logger.error("history action failed: \(String(describing: cause), privacy: .public)")
    toast = HistoryToast(kind: .error, message: message)
  }

  // MARK: List bookkeeping

  private func held(_ id: String) -> Memo? {
    memos.first { $0.id == id }
  }

  private func remove(_ id: String) {
    pinned.removeAll { $0.id == id }
    items.removeAll { $0.id == id }
  }

  /// Puts `memo` where the server's list would: replaced in place, moved between pinned and items by its state, or
  /// dropped when it no longer matches the filters. A memo the list never held is skipped while it would belong to a
  /// page that is not loaded yet, unless `force` says the caller knows better (a rollback, an undo).
  private func place(_ memo: Memo, force: Bool = false) {
    let known = held(memo.id) != nil
    remove(memo.id)
    guard filters.matches(memo) else { return }
    if !known, !force, nextCursor != nil, let tail = items.last, Self.isNewer(tail, than: memo) { return }
    if memo.isOpenNeedsRoute {
      Self.insert(memo, into: &pinned)
    } else {
      Self.insert(memo, into: &items)
    }
  }

  private static func isNewer(_ lhs: Memo, than rhs: Memo) -> Bool {
    (lhs.createdAt, lhs.id) > (rhs.createdAt, rhs.id)
  }

  private static func insert(_ memo: Memo, into list: inout [Memo]) {
    let index = list.firstIndex { isNewer(memo, than: $0) } ?? list.endIndex
    list.insert(memo, at: index)
  }
}
