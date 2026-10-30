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
  let history: HistoryModel
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

  let notifier: MemoNotifier
  private let api: any APIClient
  private let credentials: any CredentialStore
  private let reconfigurable: ReconfigurableAPIClient?
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
    let history: HistoryModel
    let client: any APIClient
    if arguments.contains(Self.fakeDataArgument) {
      let launched = Date()
      let pinned = sampleNow
      let fake = FakeAPIClient(now: { pinned.addingTimeInterval(Date().timeIntervalSince(launched)) })
      mode = .fake
      client = fake
      fakeAPI = fake
      reconfigurable = nil
      self.credentials = credentials ?? InMemoryCredentialStore()
      history = HistoryModel(client: fake)
      page = arguments.contains(Self.settingsArgument) ? .settings : .history
    } else {
      let store = credentials ?? KeychainCredentialStore()
      let saved = store.load()
      let reconfigurable = ReconfigurableAPIClient(credentials: saved)
      mode = .production
      client = reconfigurable
      fakeAPI = nil
      self.reconfigurable = reconfigurable
      self.credentials = store
      history = HistoryModel(client: reconfigurable, hiddenStore: UserDefaultsHiddenMemoStore())
      page = saved == nil ? .settings : .history
    }
    api = client
    self.history = history
    let isFake = mode == .fake
    notifier = MemoNotifier(
      poster: poster ?? (isFake ? RecordingNotificationPoster() : UserNotificationPoster()),
      lookup: { id in
        if let known = history.memos.first(where: { $0.id == id }) { return known }
        return try? await client.memo(id: id).memo
      })
    history.onMemoDone = { [notifier] id in Task { await notifier.memoDone(id: id) } }
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

  /// Starts following the server: the list, then its event stream. Called once at launch and again on each connection change.
  func begin() {
    following?.cancel()
    following = Task { [weak self] in await self?.follow() }
  }

  /// Fakes: seeds the sample memos. Then, when there is a connection: asks for notification permission, loads the list and
  /// follows `/v1/events` until cancelled.
  private func follow() async {
    if let fakeAPI { await SampleData.seed(fakeAPI, now: sampleNow) }
    guard isConfigured else { return }
    await notifier.prepare()
    await history.load()
    await history.observeEvents()
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

  private func connectionChanged() {
    reconfigurable?.reconfigure(credentials.load())
    connectionRevision += 1
    page = isConfigured ? .history : .settings
    begin()
  }
}

/// The fake composition's credential store: nothing touches the Keychain (an unsigned build gets `-34018` from it).
nonisolated final class InMemoryCredentialStore: CredentialStore {
  private let state = Mutex<ConnectionCredentials?>(nil)

  func load() -> ConnectionCredentials? { state.withLock { $0 } }
  func save(_ credentials: ConnectionCredentials) throws { state.withLock { $0 = credentials } }
  func clear() { state.withLock { $0 = nil } }
}
