import AppKit
import Foundation
import IrisCore
import CryptoKit
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
///   and each connection gets its own ``ReconfigurableAPIClient``. With nothing saved the
///   panel opens on Settings and nothing loads.
///
/// - The capture side (Wave 18 M2): under `-IrisFakeData` a scripted ``FakeTakeEngine`` and permission, no microphone and no
///   hotkey registration; otherwise ``MacCaptureStack`` (the outbox on the Mac's audio devices, uploading over the saved
///   connection), the system microphone permission and the `KeyboardShortcuts` hotkey.
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
  /// The floating recording panel's state machine, and the controller that shows the panel for it.
  let recording: RecordingPanelModel
  let recordingPanel: RecordingPanelController
  /// The global key that toggles a take.
  let hotkey: any TakeHotkey
  /// The scripted engine behind ``Mode/fake``; the snapshot run feeds its levels.
  let fakeTake: FakeTakeEngine?
  /// Production only: the outbox the takes go through, and the client its uploader talks to.
  private let capture: MacCaptureStack?
  private var hotkeyListening: Task<Void, Never>?
  private var createdListening: Task<Void, Never>?
  /// Signals each `ready` of the current connection's event stream (see ``StreamTappingClient``).
  private var streamReady: AsyncStream<Void>
  /// The client of the current connection. Each connection gets its own, so a task that started on the old server can never
  /// reach the new one.
  private var api: any APIClient
  private let credentials: any CredentialStore
  /// The fake server behind ``Mode/fake``; tests push events through it.
  let fakeAPI: FakeAPIClient?
  private let sampleNow: Date
  private var following: Task<Void, Never>?
  /// The last queued action per memo; the next one waits for it.
  private var queues: [String: (token: UUID, task: Task<Void, Never>)] = [:]
  private var clickHandler: NotificationClickHandler?

  init(
    arguments: [String] = ProcessInfo.processInfo.arguments,
    credentials: (any CredentialStore)? = nil,
    poster: (any NotificationPoster)? = nil,
    takeEngine: (any TakeEngine)? = nil,
    permission: (any MicrophonePermission)? = nil,
    hotkey: (any TakeHotkey)? = nil
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
      capture = nil
    } else {
      let store = credentials ?? KeychainCredentialStore()
      let saved = store.load()
      let reconfigurable = ReconfigurableAPIClient(credentials: saved)
      mode = .production
      client = reconfigurable
      fakeAPI = nil
      self.credentials = store
      page = saved == nil ? .settings : .history
      capture = MacCaptureStack.production(credentials: saved)
    }
    let (ready, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    streamReady = ready
    let tapped = StreamTappingClient(base: client, ready: signal)
    api = tapped
    history = Self.makeHistory(client: tapped, mode: mode)
    let isFake = mode == .fake
    notifier = MemoNotifier(
      poster: poster ?? (isFake ? RecordingNotificationPoster() : UserNotificationPoster()),
      connectionID: Self.connectionID(for: isFake ? nil : self.credentials.load()), lookup: { _ in nil })
    let engine: any TakeEngine = takeEngine ?? capture?.engine ?? FakeTakeEngine()
    fakeTake = engine as? FakeTakeEngine
    let store = self.credentials
    recording = RecordingPanelModel(
      engine: engine, permission: permission ?? (isFake ? FakeMicrophonePermission() : SystemMicrophonePermission()),
      isConfigured: { isFake || store.load() != nil })
    recordingPanel = RecordingPanelController(model: recording)
    self.hotkey = hotkey ?? (isFake ? FakeTakeHotkey() : KeyboardShortcutsHotkey())
    // Always fetched: the list's copy can be stale, and a failed refresh must not announce a memo that is still running.
    notifier.lookup = { [weak self] id in try? await self?.api.memo(id: id).memo }
    wireNotifications()
    wireCreatedMemos()
  }

  private static func makeHistory(client: any APIClient, mode: Mode) -> HistoryModel {
    mode == .fake
      ? HistoryModel(client: client) : HistoryModel(client: client, hiddenStore: UserDefaultsHiddenMemoStore())
  }

  /// What the outbox tells History, in the order it happened.
  private enum CreatedChange: Sendable {
    case created(Memo)
    /// A cancelled take: its memo is dropped and stays out of the list until its server `DELETE` settles.
    case hide(String)
    case unhide(String)
  }

  /// A memo the outbox created on the server shows in History at once, before the event stream has told the list; a cancelled
  /// take's memo goes from it at once and stays out until the server `DELETE` has settled (the iPhone's hide/settle lifecycle).
  /// One stream, one consumer: a discard and its delete settling reach History in the order they happened.
  private func wireCreatedMemos() {
    guard let created = capture?.created else { return }
    let (changes, changed) = AsyncStream.makeStream(of: CreatedChange.self)
    // Owned by the root, which lives as long as the app. Reads `history` per change: the model of the current connection.
    createdListening = Task { [weak self] in
      for await change in changes {
        guard let history = self?.history else { return }
        switch change {
        case .created(let memo): history.insert(memo)
        case .hide(let id): history.hide(id)
        case .unhide(let id): history.unhide(id)
        }
      }
    }
    Task {
      await created.setHandler { changed.yield(.created($0)) }
      await created.setForgottenHandler { changed.yield(.hide($0)) }
      await created.setSettledHandler { changed.yield(.unhide($0)) }
    }
  }

  /// Starts listening to the global key: each press toggles a take. Called once at launch.
  func installHotkey() {
    guard hotkeyListening == nil else { return }
    let presses = hotkey.presses
    // Owned by the root, which lives as long as the app.
    hotkeyListening = Task { [weak self] in
      for await _ in presses { self?.recording.toggle() }
    }
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
  ///
  /// Actions on one memo (`memoID`) run one after the other in the order they were made, so the last tap is the last request the
  /// server sees; a later action looks the memo up again when it runs (see ``MacHistoryList``), it does not act on a copy from tap time.
  func perform(
    on model: HistoryModel, memoID: String? = nil, _ action: @escaping @MainActor (HistoryModel) async -> Void
  ) {
    let revision = connectionRevision
    let previous = memoID.flatMap { queues[$0]?.task }
    let token = UUID()
    let task = Task { [weak self] in
      await previous?.value
      guard let self, revision == connectionRevision, model === history else { return }
      await action(model)
      if let memoID, queues[memoID]?.token == token { queues[memoID] = nil }
    }
    if let memoID { queues[memoID] = (token, task) }
  }

  /// The id banners carry for a saved connection: a digest of the server URL and the token, so it is the same after a restart,
  /// and a new server or a new token gives a new one. Not reversible; nothing but the app reads it.
  static func connectionID(for credentials: ConnectionCredentials?) -> String {
    guard let credentials else { return "none" }
    let digest = SHA256.hash(data: Data("\(credentials.serverURL.absoluteString)\n\(credentials.token)".utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
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

  /// Starts following the server: the list and its event stream. Called once at launch
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
    let history = history
    // Opens the outbox and sends what an earlier run left in it (a take made offline, or cut short by a quit). Then the hidden
    // ids of discarded takes whose server `DELETE` is no longer queued are let go (an outbox that cannot be opened says nothing).
    Task {
      await capture?.service.resume()
      if let pending = await capture?.service.pendingDeletionIDs() {
        history.reconcileHidden(pendingDeletions: pending)
      }
    }
    notifier.requestPermissionIfNeeded()
    // The stream does not wait for the first list request: a slow or hung list must not keep the notifications away. The stream's
    // `ready` event reloads the list on its own.
    async let list: Void = history.load()
    async let events: Void = history.observeEvents()
    async let returns: Void = countReturns(of: streamReady)
    _ = await (list, events, returns)
  }

  /// Every `ready` of the event stream after the first is the server coming back; an open detail reloads on it.
  private func countReturns(of ready: AsyncStream<Void>) async {
    for await _ in ready {
      guard !Task.isCancelled else { return }
      reconnects += 1
    }
  }

  /// Installs the click handler that opens a memo from its notification banner. Production only: the fake never posts.
  func installNotificationClicks() {
    guard mode == .production, clickHandler == nil else { return }
    let handler = NotificationClickHandler { [weak self] id, connection in
      self?.openFromNotification(id, connection: connection)
    }
    handler.install()
    clickHandler = handler
  }

  /// A clicked banner: opens the memo unless the banner is of another connection (posted before a server switch).
  func openFromNotification(_ id: String, connection: String) {
    guard connection == notifier.connectionID else { return }
    openDetail(id)
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
    let base: any APIClient =
      fakeAPI ?? ReconfigurableAPIClient(credentials: credentials.load())
    let (ready, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    streamReady = ready
    api = StreamTappingClient(base: base, ready: signal)
    history = Self.makeHistory(client: api, mode: mode)
    wireNotifications()
    notifier.reset(connectionID: Self.connectionID(for: credentials.load()))
    queues = [:]
    capture?.reconnect(credentials.load())
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
