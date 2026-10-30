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
  private(set) var isLoading = false
  private(set) var toast: HistoryToast?
  /// What the last request or the event stream says about the server; Settings' connection row reads it.
  private(set) var link = ServerLink.unknown {
    didSet { linkObservedAt = Date() }
  }
  /// When ``link`` was last set; Settings compares it with the time of its own probe, and the newer of the two wins.
  private(set) var linkObservedAt: Date?
  var filters = HistoryFilters()
  /// Told the id of a memo when the server says it is result-ready (`memo.done`); the app speaks the reply from here.
  var onMemoDone: ((String) -> Void)?
  /// Told the id of a memo on each `memo.updated`, before the list is refreshed: the moment the event reached the app.
  var onMemoUpdated: ((String) -> Void)?
  /// Bumped for a memo on each `memo.updated` event, so an open detail screen knows to reload.
  private(set) var revisions: [String: Int] = [:]

  var memos: [Memo] { pinned + items }

  private let client: any APIClient
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "history")
  private var nextCursor: String?
  private var isLoadingMore = false
  /// The filters the rows and `nextCursor` belong to. A cursor is only ever sent with the filters that issued it.
  private var loadedFilters: HistoryFilters?
  /// Bumped when a memo is deleted or restored; a response that started before that is stale and dropped, so a late
  /// flag change or refresh cannot put a deleted memo back.
  private var lifecycle: [String: Int] = [:]
  /// Memos this device discarded (a cancelled take): never shown, whatever a refresh, an event or a late create brings back
  /// before the server's delete lands. Kept in the ``HiddenMemoStore``, so a relaunch before the delete settles still
  /// hides them; ``unhide(_:)`` clears an id once its delete is over.
  private var hidden: Set<String>
  /// The ids ``hiddenStore`` held at launch; ``reconcileHidden(pendingDeletions:)`` is the only reader.
  private var restoredHidden: Set<String>
  private let hiddenStore: any HiddenMemoStore
  /// Ids hidden and then unhidden in this session. The create hand-off reaches ``insert(_:)`` on a task of its own, so it can
  /// land after the discard's delete has settled; without this the deleted memo would come back as a row.
  private var unhiddenThisSession: Set<String> = []
  /// Drops the cached media (recording, spoken reply, diagrams) of a memo that is deleted or gone.
  private let evictMedia: (String) -> Void
  /// Bumped by every first-page load; a response that finds it changed belongs to filters that are gone.
  private var generation = 0

  init(
    client: any APIClient, hiddenStore: any HiddenMemoStore = InMemoryHiddenMemoStore(),
    evictMedia: @escaping (String) -> Void = { _ in }
  ) {
    self.client = client
    self.hiddenStore = hiddenStore
    self.evictMedia = evictMedia
    let restored = hiddenStore.load()
    hidden = restored
    restoredHidden = restored
  }

  // MARK: Loading

  /// Loads the first page for the current filters. Pull to refresh, a filter change and an SSE reconnect all land here.
  func load() async {
    generation += 1
    let current = generation
    let requested = filters
    if loadedFilters != requested { reset() }
    isLoading = true
    defer { if current == generation { isLoading = false } }
    do {
      let page = try await client.listMemos(requested.query())
      guard current == generation else { return }
      // A memo answered after the first page can repeat across pinned and items: pinned first, then the new ids.
      let pinnedIDs = Set(page.pinned.map(\.id))
      pinned = page.pinned.filter { !hidden.contains($0.id) }
      items = page.items.filter { !pinnedIDs.contains($0.id) && !hidden.contains($0.id) }
      nextCursor = page.nextCursor
      loadedFilters = requested
      loadFailed = false
      hasLoaded = true
      link = .live
    } catch is CancellationError {
      return
    } catch {
      guard current == generation else { return }
      note(failure: error)
      logger.error("history load failed: \(String(describing: error), privacy: .public)")
      loadFailed = true
      // Rows from before the failure stay on a plain refresh; the error state takes over when there are none.
      if !memos.isEmpty { toast = HistoryToast(kind: .error, message: Self.loadFailedMessage) }
    }
  }

  private static var loadFailedMessage: String {
    String(localized: "Could not load memos", comment: "History error title")
  }

  /// Drops the rows and the cursor of filters that no longer apply.
  private func reset() {
    pinned = []
    items = []
    nextCursor = nil
    loadedFilters = nil
  }

  /// Fetches the next page when `memo` is the last row on screen.
  func loadMoreIfNeeded(current memo: Memo) async {
    guard let cursor = nextCursor, let paging = loadedFilters, paging == filters, !isLoadingMore,
      memo.id == items.last?.id
    else { return }
    isLoadingMore = true
    defer { isLoadingMore = false }
    let loading = generation
    do {
      let page = try await client.listMemos(paging.query(cursor: cursor))
      guard loading == generation else { return }
      let known = Set(memos.map(\.id))
      items += page.items.filter { !known.contains($0.id) && !hidden.contains($0.id) }
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
          link = .live
          await handle(event)
        }
        // The server closed the stream: unknown until the next one says `ready`. A cancelled follow is the screen going away,
        // which says nothing about the server.
        if !Task.isCancelled { link = .unknown }
      } catch {
        if !Task.isCancelled { note(failure: error) }
        logger.error("history events dropped: \(String(describing: error), privacy: .public)")
      }
      guard (try? await Task.sleep(for: .seconds(3))) != nil else { return }
    }
  }

  /// A request failed: a 401 means the token is wrong, a transport failure (no answer at all) means the server cannot be
  /// reached, and so does a gateway 5xx (a proxy page, no contract body); any other failure (the server's own error, a body that
  /// does not decode) is an answer, so the server is there and the link stays.
  private func note(failure error: any Error) {
    if error is CancellationError { return }
    if error is URLError {
      link = .unreachable
      return
    }
    switch error as? APIError {
    case .unauthorized?: link = .rejected
    case .transport?: link = .unreachable
    case .unexpectedStatus(let status)? where Self.isGatewayFailure(status): link = .unreachable
    default: break
    }
  }

  /// A 502, 503 or 504 whose body is not the contract's error body comes from a proxy or tunnel in front of the server, which
  /// is then not answering. (The server's own 5xx carries a JSON body and is an answer.)
  private static func isGatewayFailure(_ status: Int) -> Bool {
    [502, 503, 504].contains(status)
  }

  func revision(of id: String) -> Int {
    revisions[id, default: 0]
  }

  func handle(_ event: ServerEvent) async {
    switch event {
    case .ready:
      await load()
    case .memoUpdated(let update):
      onMemoUpdated?(update.id)
      revisions[update.id, default: 0] += 1
      await refresh(id: update.id)
    case .memoDone(let done):
      // Always follows a `memo.updated` for the same state, which has already refreshed the list.
      onMemoDone?(done.id)
    }
  }

  /// The event carries the state only, so the flags come from the memo itself.
  private func refresh(id: String) async {
    if filters.needsServerMatching, !memos.contains(where: { $0.id == id }) {
      await load()
      return
    }
    let started = lifecycle[id]
    do {
      let memo = try await client.memo(id: id).memo
      guard lifecycle[id] == started else { return }
      if memo.isDeleted { evictMedia(id) }
      place(memo)
    } catch let error as APIError {
      if case .server(404, _) = error {
        guard lifecycle[id] == started else { return }
        remove(id)
        evictMedia(id)
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
    lifecycle[before.id, default: 0] += 1
    let started = lifecycle[before.id]
    remove(before.id)
    do {
      let deleted = try await client.deleteMemo(id: before.id)
      guard lifecycle[before.id] == started else { return }
      evictMedia(deleted.id)
      toast = HistoryToast(
        kind: .undoDelete(memoID: deleted.id),
        message: String(localized: "Memo deleted", comment: "Toast after a swipe delete"))
    } catch is CancellationError {
      if lifecycle[before.id] == started { place(before, force: true) }
    } catch {
      guard lifecycle[before.id] == started else { return }
      place(before, force: true)
      show(error: String(localized: "Could not delete the memo", comment: "Toast when a delete failed"), cause: error)
    }
  }

  func undoDelete() async {
    guard case .undoDelete(let id)? = toast?.kind else { return }
    toast = nil
    lifecycle[id, default: 0] += 1
    let started = lifecycle[id]
    do {
      let restored = try await client.restoreMemo(id: id)
      guard lifecycle[id] == started else { return }
      // The owner asked for it back: whatever hid and unhid it earlier in this session no longer applies.
      unhiddenThisSession.remove(id)
      place(restored, force: true)
    } catch is CancellationError {
      return
    } catch {
      guard lifecycle[id] == started else { return }
      show(error: String(localized: "Could not restore the memo", comment: "Toast when an undo failed"), cause: error)
    }
  }

  /// Shows a memo this device just created (a typed memo) without waiting for the next refresh. A memo this session hid and
  /// unhid is left to the server's list: the hand-off that carries it is not ordered against the hidden-change channel.
  func insert(_ memo: Memo) {
    guard !unhiddenThisSession.contains(memo.id) else { return }
    place(memo, force: true)
  }

  /// Drops a memo this device discarded (a cancelled take) and keeps it out of the list from here on.
  func hide(_ id: String) {
    restoredHidden.remove(id)
    hidden.insert(id)
    hiddenStore.save(hidden)
    lifecycle[id, default: 0] += 1
    remove(id)
    evictMedia(id)
  }

  /// Forgets the hidden ids restored from the last session that have no server `DELETE` queued any more (a discarded take
  /// whose create never reached the server has none to settle, and a crash can lose a settle). Only ids restored at launch
  /// are considered, so a memo hidden in this session while the outbox was being read is never dropped. Runs once.
  func reconcileHidden(pendingDeletions: Set<String>) {
    let stale = restoredHidden.subtracting(pendingDeletions)
    restoredHidden = []
    guard !hidden.isDisjoint(with: stale) else { return }
    hidden.subtract(stale)
    hiddenStore.save(hidden)
  }

  /// The discard's server delete is over: the server's list decides again. A memo that is gone stays out of it, and one the
  /// server kept (it left `receiving` before the delete landed) shows up with the next refresh.
  func unhide(_ id: String) {
    guard hidden.remove(id) != nil else { return }
    unhiddenThisSession.insert(id)
    hiddenStore.save(hidden)
  }

  /// A memo went to the outbox instead of the server: say so, it shows up here once it is sent.
  func didQueue() {
    toast = HistoryToast(
      kind: .info,
      message: String(
        localized: "Queued. It is sent as soon as the server answers.", comment: "Toast after a memo went to the outbox"
      ))
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
    let started = lifecycle[before.id]
    do {
      let saved = try await client.setFlags(id: before.id, done: done, favorite: favorite, archived: archived)
      guard lifecycle[before.id] == started else { return }
      place(saved, force: true)
    } catch is CancellationError {
      if lifecycle[before.id] == started { place(before, force: true) }
    } catch {
      guard lifecycle[before.id] == started else { return }
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
    guard !hidden.contains(memo.id), filters.matches(memo) else { return }
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

/// What the app's own traffic says about the server right now, as opposed to the health probe Settings runs when it appears
/// (``SettingsModel/Connection``): History's event stream and list loads are authenticated and continuous, so a dropped
/// network, a Tailscale that is off or a rejected token shows here within seconds.
enum ServerLink: Equatable {
  /// Nothing has been tried yet.
  case unknown
  /// The last request or the event stream got an answer.
  case live
  /// The last request or the event stream never reached the server.
  case unreachable
  /// The server answered 401: the saved device token is wrong.
  case rejected
}
