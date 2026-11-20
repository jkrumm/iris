import Foundation
import IrisCore
import Observation
import os

/// The memo list behind History (and, via `load()` and `memos`, the Mac menu bar panel): paging, filters, SSE
/// updates and the optimistic flag actions, all through an `APIClient`.
@Observable
final class HistoryModel {
  private(set) var items: [Memo] = [] {
    didSet { regroup() }
  }
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

  var memos: [Memo] { items }

  /// More pages exist than ``memos`` holds.
  var hasMorePages: Bool { nextCursor != nil }

  /// ``memos`` grouped into day sections, rebuilt when the list changes rather than by every evaluation of the view.
  private(set) var sections: [HistoryDaySection] = []
  /// The ids of ``memos`` in order: what the list animates on, so a reorder animates and a flag change does not.
  private(set) var memoIDs: [String] = []

  /// What the lists show, newest first: one row per conversation. The server collapses a thread to its newest memo (`collapse=thread`),
  /// so the rows are ``memos`` as they are; a search finds a conversation by any of its turns.
  var listedMemos: [Memo] { items }

  private func regroup() {
    let rows = listedMemos
    sections = HistoryDaySection.group(rows)
    memoIDs = rows.map(\.id)
  }

  private let client: any APIClient
  /// The key of the server `client` talks to now. A response is merged only when it is still the same server it was asked of:
  /// after a connection switch an answer from the old one belongs to a list that is gone.
  private let serverKey: () -> String?
  /// The server the rows and `nextCursor` came from.
  private var loadedServer: String?
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "history")
  @ObservationIgnored private var liveContinuations: [UUID: AsyncStream<ServerEvent>.Continuation] = [:]
  /// How many live streams are open.
  var liveStreamCount: Int { liveContinuations.count }
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
  /// The rows of conversations this session deleted, by the id the delete answered with, for the undo (the restore answers with the
  /// memo alone, so the row comes back as the conversation it was).
  private var deletedConversations: [String: Memo] = [:]
  /// The ids ``hiddenStore`` held at launch; ``reconcileHidden(pendingDeletions:)`` is the only reader.
  private var restoredHidden: Set<String>
  private let hiddenStore: any HiddenMemoStore
  /// Ids hidden and then unhidden in this session. The create hand-off reaches ``insert(_:)`` on a task of its own, so it can
  /// land after the discard's delete has settled; without this the deleted memo would come back as a row.
  private var unhiddenThisSession: Set<String> = []
  /// Drops the cached media (recording, spoken reply, diagrams) of a memo that is deleted or gone.
  private let evictMedia: (String) -> Void
  /// Where Copy puts a transcript; nil where the host has no Copy on a row (the Mac panel).
  private let pasteboard: (any Pasteboard)?
  /// Bumped by every first-page load; a response that finds it changed belongs to filters that are gone.
  private var generation = 0
  /// Counts the first-page loads that ended in an answer or a failure of their own (not superseded ones); see `firstPage(after:timeout:)`.
  private(set) var loadsFinished = 0
  /// What the last finished load brought, raw (before the local hides), when it was a load with no filter; nil when it was
  /// filtered or failed.
  private var lastPage: (serial: Int, items: [Memo]?)?
  private var pageWaiters: [UUID: CheckedContinuation<[Memo]?, Never>] = [:]

  /// Ids whose delete settled before their hide arrived (a cancelled take's `DELETE` can be acknowledged before the cancel has
  /// told History): the hide then removes the row but does not keep the id hidden, since there is nothing left to wait for.
  private var settledBeforeHide: Set<String> = []

  /// - Parameter serverKey: The server `client` sends to; by default read from a ``ReconfigurableAPIClient``, `nil` for any
  ///   other client (a fake), which then never sees a switch.
  init(
    client: any APIClient, hiddenStore: any HiddenMemoStore = InMemoryHiddenMemoStore(),
    evictMedia: @escaping (String) -> Void = { _ in }, serverKey: (() -> String?)? = nil,
    pasteboard: (any Pasteboard)? = nil
  ) {
    self.pasteboard = pasteboard
    self.client = client
    self.serverKey = serverKey ?? { (client as? ReconfigurableAPIClient)?.serverKey }
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
    let server = serverKey()
    // Rows of the old server are not shown while the new one's first page is on its way.
    if loadedFilters != requested || loadedServer != server { reset() }
    isLoading = true
    defer { if current == generation { isLoading = false } }
    do {
      let page = try await client.listMemos(requested.query())
      guard current == generation, server == serverKey() else { return }
      items = page.items.filter { !hidden.contains($0.id) }
      nextCursor = page.nextCursor
      loadedFilters = requested
      loadedServer = server
      loadFailed = false
      hasLoaded = true
      link = .live
      finishLoad(page: requested == HistoryFilters() ? page.items : nil)
    } catch is CancellationError {
      return
    } catch {
      guard current == generation, server == serverKey() else { return }
      note(failure: error)
      logger.error("history load failed: \(String(describing: error), privacy: .public)")
      finishLoad(page: nil)
      loadFailed = true
      // Rows from before the failure stay on a plain refresh; the error state takes over when there are none.
      if !memos.isEmpty { toast = HistoryToast(kind: .error, message: Self.loadFailedMessage) }
    }
  }

  private func finishLoad(page: [Memo]?) {
    loadsFinished += 1
    lastPage = (loadsFinished, page)
    let waiting = pageWaiters
    pageWaiters = [:]
    for waiter in waiting.values { waiter.resume(returning: page) }
  }

  /// The newest memos, unfiltered, from the first load that finishes after `serial` (a `loadsFinished` read earlier), so a caller
  /// that wants the same page as this list does not ask the server for it a second time. nil when that load was filtered or
  /// failed, or when it does not finish within `timeout` (a hung list must not hold the caller back).
  func firstPage(after serial: Int, timeout: Duration = .seconds(4)) async -> [Memo]? {
    await withTaskGroup(of: [Memo]?.self) { group in
      group.addTask { await self.waitForPage(after: serial) }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }

  private func waitForPage(after serial: Int) async -> [Memo]? {
    let key = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (waiter: CheckedContinuation<[Memo]?, Never>) in
        if let last = lastPage, last.serial > serial {
          waiter.resume(returning: last.items)
        } else if Task.isCancelled {
          waiter.resume(returning: nil)
        } else {
          pageWaiters[key] = waiter
        }
      }
    } onCancel: {
      Task { @MainActor in self.pageWaiters.removeValue(forKey: key)?.resume(returning: nil) }
    }
  }

  private static var loadFailedMessage: String {
    String(localized: "Could not load memos", comment: "History error title")
  }

  /// Drops the rows and the cursor of filters that no longer apply.
  private func reset() {
    items = []
    nextCursor = nil
    loadedFilters = nil
    loadedServer = nil
  }

  /// The row that stands for `memo`: the row of the memo itself, else of the conversation it is a turn of (a row is its conversation's
  /// newest memo, so the first memo an open conversation shows is found through the thread or the row's conversation id).
  func row(for memo: Memo) -> Memo? {
    items.first { $0.id == memo.id }
      ?? items.first { memo.threadId != nil && $0.threadId == memo.threadId }
      ?? items.first { $0.conversation?.id == memo.id }
  }

  /// Fetches the next page when `memo` is the last row on screen.
  func loadMoreIfNeeded(current memo: Memo) async {
    let server = serverKey()
    guard let cursor = nextCursor, let paging = loadedFilters, paging == filters, !isLoadingMore,
      memo.id == items.last?.id, loadedServer == server
    else { return }
    isLoadingMore = true
    defer { isLoadingMore = false }
    let loading = generation
    do {
      let page = try await client.listMemos(paging.query(cursor: cursor))
      guard loading == generation, server == serverKey() else { return }
      let known = Set(memos.map(\.id))
      let fresh = page.items.filter { !known.contains($0.id) && !hidden.contains($0.id) }
      // A row of the list that stands for a conversation this page brings its own row of (an older turn opened from a banner and held
      // as a stand-in) gives way to it: one row per conversation.
      let threads = Set(fresh.compactMap(\.threadId))
      items.removeAll { $0.threadId.map(threads.contains) ?? false }
      items += fresh
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

  /// The revision of a transcript as one: the memo's own, its first part's, every loaded part's, and how many there are, so an open
  /// transcript reloads when any recording of it changes or another one joins.
  func transcriptRevision(of memo: Memo) -> Int {
    guard let thread = memo.transcriptThreadID else { return revision(of: memo.id) }
    return items.reduce(revision(of: memo.id) &+ revision(of: thread)) { total, other in
      other.threadId == thread ? total &+ revision(of: other.id) &+ 1 : total
    }
  }

  /// The events a conversation screen follows live (`ready`, `memo.delta`, `memo.activity`), multicast to every open stream. The
  /// text of a delta is display only: it is yielded and never kept or logged here.
  func liveEvents() -> AsyncStream<ServerEvent> {
    let (stream, continuation) = AsyncStream.makeStream(of: ServerEvent.self, bufferingPolicy: .unbounded)
    let key = UUID()
    liveContinuations[key] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor in self?.liveContinuations[key] = nil }
    }
    return stream
  }

  private func publish(_ event: ServerEvent) {
    for continuation in liveContinuations.values { continuation.yield(event) }
  }

  func handle(_ event: ServerEvent) async {
    switch event {
    case .ready:
      publish(event)
      await load()
    case .memoUpdated(let update):
      onMemoUpdated?(update.id)
      revisions[update.id, default: 0] += 1
      await refresh(id: update.id)
    case .memoDone(let done):
      // Always follows a `memo.updated` for the same state, which has already refreshed the list.
      onMemoDone?(done.id)
    case .memoDelta, .memoActivity:
      // Live reply text and tool activity: no list row shows it (an open conversation does), the final `memo.updated` carries the result.
      publish(event)
    }
  }

  /// The event carries the state only, so the flags come from the memo itself.
  private func refresh(id: String) async {
    if filters.needsServerMatching, !memos.contains(where: { $0.id == id }) {
      await load()
      return
    }
    let started = lifecycle[id]
    let server = serverKey()
    do {
      let memo = try await client.memo(id: id).memo
      guard lifecycle[id] == started, server == serverKey() else { return }
      if memo.isDeleted { evictMedia(id) }
      // A conversation row's star is the thread's (any turn), which the memo alone cannot say: when the newest turn reads unstarred under
      // a starred row, the server's list decides (another device unstarred the thread, or an older turn holds the star).
      if let held = items.first(where: { $0.id == memo.id }), held.conversation != nil, held.favorite, !memo.favorite {
        await load()
        return
      }
      // A reply into a conversation the list does not hold a row of yet: the server knows its title and turns, the event does not.
      if row(for: memo) == nil, memo.continuesThread, filters.matches(memo), isWithinLoadedRows(memo) {
        await load()
        return
      }
      // One turn deleted alone (a client with no `scope`) leaves its conversation's earlier turns without a row: the server's list decides.
      if memo.isDeleted, let held = items.first(where: { $0.id == memo.id }), (held.conversation?.turns ?? 0) > 1 {
        await load()
        return
      }
      place(memo)
    } catch let error as APIError {
      if case .server(404, _) = error {
        // A 404 from the server this memo's event did not come from says nothing about the memo.
        guard lifecycle[id] == started, server == serverKey() else { return }
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
    guard let before = row(for: memo), before.state.isDeletable else { return }
    lifecycle[before.id, default: 0] += 1
    let started = lifecycle[before.id]
    remove(before.id)
    do {
      let deleted = try await client.deleteMemo(id: before.id, scope: Self.scope(of: before))
      guard lifecycle[before.id] == started else { return }
      evictMedia(deleted.id)
      if before.conversation != nil { deletedConversations[deleted.id] = before }
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
      let deletedRow = deletedConversations[id]
      var restored = try await client.restoreMemo(id: id, scope: deletedRow == nil ? .memo : .thread)
      guard lifecycle[id] == started else { return }
      deletedConversations[id] = nil
      // The owner asked for it back: whatever hid and unhid it earlier in this session no longer applies.
      unhiddenThisSession.remove(id)
      // The row comes back as the conversation it was: the restore answers with the memo alone.
      restored.conversation = deletedRow?.conversation
      place(restored, force: true)
    } catch is CancellationError {
      return
    } catch {
      guard lifecycle[id] == started else { return }
      show(error: String(localized: "Could not restore the memo", comment: "Toast when an undo failed"), cause: error)
    }
  }

  /// Shows a memo this device just created (a typed memo) without waiting for the next refresh. A memo this session hid and
  /// unhid is left to the server's list: the hand-off that carries it is not ordered against the hidden-change channel. A memo
  /// created on another server than the one shown now (`origin`; the hand-off can arrive after a connection switch) is not
  /// this list's: the server it lives on is not the one History reads.
  func insert(_ memo: Memo, origin: String? = nil) {
    if let origin, origin != serverKey() { return }
    guard !unhiddenThisSession.contains(memo.id) else { return }
    place(memo, force: true)
  }

  /// Drops a memo this device discarded (a cancelled take) and keeps it out of the list from here on.
  func hide(_ id: String) {
    restoredHidden.remove(id)
    lifecycle[id, default: 0] += 1
    // The server's delete was over before this arrived: the row goes, but nothing is left that would unhide the id again.
    if settledBeforeHide.remove(id) != nil {
      remove(id)
      evictMedia(id)
      return
    }
    hidden.insert(id)
    hiddenStore.save(hidden)
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
    guard hidden.remove(id) != nil else {
      // Not hidden (yet): the settle outran the hide. Remembered, so the hide that follows does not outlive its delete.
      settledBeforeHide.insert(id)
      unhiddenThisSession.insert(id)
      return
    }
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

  /// Puts the memo's transcript on the pasteboard as plain text and confirms with a toast; nothing for a memo without one. A
  /// transcript continued with more recordings is copied whole: its parts are read from the server (the loaded rows when that
  /// fails), the first part's text alone only when neither has more.
  @discardableResult
  func copyTranscript(of memo: Memo) -> Task<Void, Never>? {
    guard let pasteboard, let text = memo.plainTranscript else { return nil }
    // The first part's row may predate the continuation (the server promotes it without an event): the loaded parts say so.
    let thread = memo.threadId ?? (items.contains { $0.threadId == memo.id } ? memo.id : nil)
    guard memo.mode == .transcribe, !memo.isDeleted, let thread else {
      copied(text, to: pasteboard)
      return nil
    }
    return Task {
      let loaded: [Memo]?
      do {
        loaded = try await client.thread(id: thread).memos
      } catch {
        loaded = nil
        // A conversation's row holds only its newest part: one part is not passed off as the transcript.
        if memo.conversation != nil {
          show(
            error: String(
              localized: "Could not load the conversation", comment: "Toast when Copy could not read every part"),
            cause: error)
          return
        }
      }
      let parts = loaded ?? items.filter { $0.threadId == thread }
      let ordered = parts.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
      copied(TranscriptText.whole(of: ordered) ?? text, to: pasteboard)
    }
  }

  private func copied(_ text: String, to pasteboard: any Pasteboard) {
    pasteboard.copy(text)
    toast = HistoryToast(
      kind: .info, message: String(localized: "Transcript copied", comment: "Toast after Copy on a memo row"))
  }

  func dismissToast(id: HistoryToast.ID) {
    if toast?.id == id { toast = nil }
  }

  /// Applies the flags to the row first and rolls it back (position included) when the server refuses.
  private func update(_ memo: Memo, done: Bool? = nil, favorite: Bool? = nil, archived: Bool? = nil) async {
    guard let before = row(for: memo) else { return }
    var after = before
    after.done = done ?? after.done
    after.favorite = favorite ?? after.favorite
    after.archived = archived ?? after.archived
    place(after, force: true)
    let started = lifecycle[before.id]
    do {
      let saved = try await client.setFlags(
        id: before.id, done: done, favorite: favorite, archived: archived, scope: Self.scope(of: before))
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

  /// A row of a conversation acts on every turn of it (flags, delete, undo); a memo on its own acts alone.
  private static func scope(of row: Memo) -> MemoScope {
    row.conversation == nil ? .memo : .thread
  }

  /// `memo` is at least as new as the oldest row the list holds, or the list holds all its rows: it would sit among the loaded rows.
  private func isWithinLoadedRows(_ memo: Memo) -> Bool {
    guard nextCursor != nil, let tail = items.last else { return true }
    return !Self.isNewer(tail, than: memo)
  }

  private func remove(_ id: String) {
    items.removeAll { $0.id == id }
  }

  /// Puts `memo` where the server's list would: replaced in place, or dropped when it
  /// no longer matches the filters. A memo the list never held is skipped while it would belong to a
  /// page that is not loaded yet, unless `force` says the caller knows better (a rollback, an undo).
  ///
  /// A row is its conversation's newest memo, so a memo of a thread the list already holds a row of takes that row's place: an update of
  /// the row's own memo keeps its conversation, a newer turn replaces the row (the title stays, the turn count and the time move, the
  /// row re-sorts), an older turn changes nothing.
  private func place(_ memo: Memo, force: Bool = false) {
    if let index = items.firstIndex(where: { $0.id == memo.id }) {
      var row = memo
      if row.conversation == nil { row.conversation = items[index].conversation }
      items.remove(at: index)
      guard !hidden.contains(row.id), filters.matches(row) else { return }
      Self.insert(row, into: &items)
      return
    }
    if let threadId = memo.threadId, !memo.isDeleted, let index = items.firstIndex(where: { $0.threadId == threadId }) {
      let held = items[index]
      guard Self.isNewer(memo, than: held) else { return }
      var row = memo
      row.conversation = MemoConversation(
        id: held.conversation?.id ?? held.id, title: held.conversation?.title ?? held.rowHeadline,
        turns: (held.conversation?.turns ?? 1) + 1)
      items.remove(at: index)
      guard !hidden.contains(row.id), filters.matches(row) else { return }
      Self.insert(row, into: &items)
      return
    }
    guard !hidden.contains(memo.id), filters.matches(memo) else { return }
    if !force, nextCursor != nil, let tail = items.last, Self.isNewer(tail, than: memo) { return }
    Self.insert(memo, into: &items)
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
