import AppKit
import Foundation
import IrisCore
import Observation
import Synchronization

/// The page the menu-bar panel shows.
enum MacPanelPage: Equatable {
  case history
  case settings
}

/// The one place that decides which adapters the Mac app runs on. Launch arguments are read here, once.
///
/// - `-IrisFakeData` (screenshots, tests): the fake API client with the sample memos, an in-memory credential store (an
///   unsigned build has no Keychain, `-34018`) and a poster that records instead of notifying.
/// - Otherwise: production. The server URL and device token come from the panel's Settings page (token in the Keychain),
///   and every model holds one ``ReconfigurableAPIClient``, which follows the saved connection. With nothing saved the
///   panel opens on Settings and nothing loads.
///
/// History's list and event stream run from launch, not from the first time the popover opens: a notification per finished
/// memo needs the stream while the panel is closed.
@MainActor
@Observable
final class MacCompositionRoot {
  enum Mode: Equatable {
    case fake
    case production
  }

  let mode: Mode
  /// The memo list of the current connection; a connection change replaces it, so nothing of the old server stays.
  private(set) var history: HistoryModel
  /// The editable connection (server URL + token).
  @ObservationIgnored private(set) lazy var connectionForm = ConnectionModel(store: credentials) {
    [unowned self] in connectionChanged()
  }
  /// Bumped when the saved connection changes.
  private(set) var connectionRevision = 0
  var page: MacPanelPage
  /// The memo the detail panel shows; nil until a row is opened.
  private(set) var detailMemoID: String?
  /// Bumped by every ``openDetail(_:)``; the always-present menu-bar label opens the detail window when it changes.
  private(set) var detailRequest = 0
  /// Bumped when the detail window must close (the connection moved to another server).
  private(set) var detailDismissals = 0
  /// Times the server came back after the stream had been down; an open detail reloads on each.
  private(set) var reconnects = 0

  let notifier: MemoNotifier
  /// The client of the current connection. Each connection gets its own, so a task that started on the old server can never
  /// reach the new one.
  private var api: any APIClient
  private let credentials: any CredentialStore
  /// The fake server behind ``Mode/fake``; tests push events through it.
  let fakeAPI: FakeAPIClient?
  private let sampleNow: Date
  private var following: Task<Void, Never>?
  private var clickHandler: NotificationClickHandler?

  init(
    arguments: [String] = ProcessInfo.processInfo.arguments,
    credentials: (any CredentialStore)? = nil,
    poster: (any NotificationPoster)? = nil
  ) {
    sampleNow = SampleData.now(arguments: arguments)
    let client: any APIClient
    if arguments.contains(Self.fakeDataArgument) {
      let launched = Date()
      let pinned = sampleNow
      let fake = FakeAPIClient(now: { pinned.addingTimeInterval(Date().timeIntervalSince(launched)) })
      mode = .fake
      client = fake
      fakeAPI = fake
      self.credentials = credentials ?? InMemoryCredentialStore()
      page = arguments.contains(Self.settingsArgument) ? .settings : .history
    } else {
      let store = credentials ?? KeychainCredentialStore()
      let saved = store.load()
      let reconfigurable = ReconfigurableAPIClient(credentials: saved)
      mode = .production
      client = reconfigurable
      fakeAPI = nil
      self.credentials = store
      page = saved == nil ? .settings : .history
    }
    api = client
    history = Self.makeHistory(client: client, mode: mode)
    let isFake = mode == .fake
    notifier = MemoNotifier(
      poster: poster ?? (isFake ? RecordingNotificationPoster() : UserNotificationPoster()), lookup: { _ in nil })
    notifier.lookup = { [weak self] id in
      guard let self else { return nil }
      if let known = history.memos.first(where: { $0.id == id }) { return known }
      return try? await api.memo(id: id).memo
    }
    wireNotifications()
  }

  private static func makeHistory(client: any APIClient, mode: Mode) -> HistoryModel {
    mode == .fake
      ? HistoryModel(client: client) : HistoryModel(client: client, hiddenStore: UserDefaultsHiddenMemoStore())
  }

  private func wireNotifications() {
    history.onMemoDone = { [weak self, notifier] id in self?.announce(id, with: notifier) }
  }

  /// The generation is read now, not when the task runs: an event of the old server that only gets to run after a switch is dropped.
  private func announce(_ id: String, with notifier: MemoNotifier) {
    let generation = notifier.generation
    Task { await notifier.memoDone(id: id, generation: generation) }
  }

  /// Runs a row action of the list on the model it was made for, and drops it when the connection has changed since: it must
  /// never act on the new server.
  func perform(on model: HistoryModel, _ action: @escaping @MainActor (HistoryModel) async -> Void) {
    let revision = connectionRevision
    Task { [weak self] in
      guard let self, revision == connectionRevision, model === history else { return }
      await action(model)
    }
  }

  static let fakeDataArgument = "-IrisFakeData"
  /// Opens the panel on the Settings page (screenshots).
  static let settingsArgument = "-IrisMacSettings"
  /// Opens the panel as a regular window at launch, because a menu-bar popover cannot be opened without a click
  /// (screenshots).
  static let panelWindowArgument = "-IrisMacPanelWindow"

  /// A server URL and token are saved (always true on fakes). Reads `connectionRevision`, so a view that shows this follows
  /// the connection form's saves.
  var isConfigured: Bool {
    _ = connectionRevision
    return mode == .fake || credentials.load() != nil
  }

  /// Starts following the server: the list, its event stream and the watch for memos that finished unseen. Called once at launch
  /// and again on each connection change.
  func begin() {
    following?.cancel()
    following = Task { [weak self] in await self?.follow() }
  }

  /// Fakes: seeds the sample memos. Then, when there is a connection: loads the list and follows `/v1/events` until cancelled.
  /// The notification prompt is shown on the side: an unanswered prompt never holds History or the stream back.
  private func follow() async {
    if let fakeAPI { await SampleData.seed(fakeAPI, now: sampleNow) }
    guard isConfigured else { return }
    notifier.requestPermissionIfNeeded()
    let history = history
    async let events: Void = followEvents(of: history)
    async let completions: Void = watch(history)
    _ = await (events, completions)
  }

  private func followEvents(of history: HistoryModel) async {
    await history.load()
    await history.observeEvents()
  }

  /// Follows what History shows. A memo that is done in a snapshot but was not in the one before is announced (a `memo.done`
  /// lost to an outage; the notifier drops the ones the event already announced), and every return of the connection bumps
  /// ``reconnects``.
  private func watch(_ history: HistoryModel) async {
    let revision = connectionRevision
    var catchUp = DoneCatchUp()
    var link = LinkTracker()
    let snapshots = Observations {
      Snapshot(memos: history.memos, hasLoaded: history.hasLoaded, filters: history.filters, link: history.link)
    }
    for await snapshot in snapshots {
      // A snapshot of the old server that is still in flight when the connection changes must not touch the new one.
      guard !Task.isCancelled, revision == connectionRevision else { return }
      if link.cameBack(snapshot.link) {
        reconnects += 1
        notifier.retryFailed()
      }
      let finished = catchUp.newlyDone(in: snapshot.memos, hasLoaded: snapshot.hasLoaded, filters: snapshot.filters)
      for id in finished { announce(id, with: notifier) }
    }
  }

  private struct Snapshot: Sendable {
    let memos: [Memo]
    let hasLoaded: Bool
    let filters: HistoryFilters
    let link: ServerLink
  }

  /// Installs the click handler that opens a memo from its notification banner. Production only: the fake never posts.
  func installNotificationClicks() {
    guard mode == .production, clickHandler == nil else { return }
    let handler = NotificationClickHandler { [weak self] id in self?.openDetail(id) }
    handler.install()
    clickHandler = handler
  }

  /// Shows `id` in the detail panel: a row, or a clicked notification banner.
  func openDetail(_ id: String) {
    detailMemoID = id
    detailRequest += 1
  }

  /// The model behind the detail panel for `id`: the list's copy of the memo shows at once, the first load brings the steps.
  func detailModel(for id: String) -> MacMemoDetailModel {
    MacMemoDetailModel(
      memoID: id, memo: history.memos.first { $0.id == id }, client: api, pasteboard: MacPasteboard())
  }

  /// The saved connection changed: everything that belongs to the old server goes (its list, the open detail and the window,
  /// what was announced), the client points at the new one, and following starts over.
  private func connectionChanged() {
    following?.cancel()
    if mode == .production { api = ReconfigurableAPIClient(credentials: credentials.load()) }
    history = Self.makeHistory(client: api, mode: mode)
    wireNotifications()
    notifier.reset()
    closeDetail()
    reconnects = 0
    connectionRevision += 1
    page = isConfigured ? .history : .settings
    begin()
  }

  private func closeDetail() {
    detailMemoID = nil
    detailDismissals += 1
  }
}

/// The fake composition's credential store: nothing touches the Keychain (an unsigned build gets `-34018` from it).
nonisolated final class InMemoryCredentialStore: CredentialStore {
  private let state = Mutex<ConnectionCredentials?>(nil)

  func load() -> ConnectionCredentials? { state.withLock { $0 } }
  func save(_ credentials: ConnectionCredentials) throws { state.withLock { $0 = credentials } }
  func clear() { state.withLock { $0 = nil } }
}
