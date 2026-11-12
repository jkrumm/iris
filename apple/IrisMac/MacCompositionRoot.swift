import AppKit
import Foundation
import IrisCapture
import IrisCore
import IrisUI
import CryptoKit
import Observation
import Synchronization

/// The tabs of the Settings scene.
enum MacSettingsTab: Hashable {
  case connection
  case recording
  case general
}

/// The one place that decides which adapters the Mac app runs on. Launch arguments are read here, once.
///
/// - `-IrisFakeData` (screenshots, tests): the fake API client with the sample memos, an in-memory credential store (an
///   unsigned build has no Keychain, `-34018`) and a poster that records instead of notifying.
/// - Otherwise: production. The server URL and device token come from the Settings scene or the onboarding window (token in the
///   Keychain), and each connection gets its own ``ReconfigurableAPIClient``. With nothing saved the popover shows a connect
///   prompt, the onboarding window opens at launch and nothing loads.
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
  /// The popover's memo list (always unfiltered: the newest memos) of the current connection; a
  /// connection change replaces it, so nothing of the old server stays.
  private(set) var history: HistoryModel
  /// The main window's own list: the sidebar scope and the search narrow it, so it never fights the popover's. It loads and follows
  /// events only while the window is open (``windowDidAppear()``); events come over a client of its own, so the popover's
  /// stream tap counts no second `ready`.
  private(set) var windowHistory: HistoryModel
  /// The editable connection (server URL + token).
  @ObservationIgnored private(set) lazy var connectionForm = ConnectionModel(store: credentials) {
    [unowned self] in connectionChanged()
  }
  /// Probes a server with the values typed in Settings, before or after saving them.
  @ObservationIgnored private(set) lazy var connectionTest = ConnectionTester { [fakeAPI] credentials in
    if let fakeAPI { return fakeAPI }
    return URLSessionAPIClient(baseURL: credentials.serverURL, bearerToken: credentials.token)
  }
  /// Bumped when the saved connection changes.
  private(set) var connectionRevision = 0
  /// The main window's sidebar selection. Choosing one narrows ``windowHistory`` to it (the search text stays); the sidebar's list
  /// can deselect, which keeps the current scope.
  var scope: MacLibraryScope? = .all {
    didSet {
      guard let scope else {
        self.scope = oldValue
        return
      }
      var filters = windowHistory.filters
      scope.apply(to: &filters)
      guard filters != windowHistory.filters else { return }
      windowHistory.filters = filters
    }
  }
  /// The memo the main window shows in its detail column; nil until one is selected.
  var selectedMemoID: String?
  /// Bumped by every ``show(_:)``; the always-present menu-bar label opens the main window when it changes.
  private(set) var windowRequest = 0
  /// The app was started by the user (not at login) and the main window is still to open: the menu-bar label takes it once
  /// (``takeLaunchWindow()``), because only a view can open a window.
  private(set) var launchWindowPending = false
  /// The main window is the key window. The global key continues the conversation open in it (``frontConversationThreadID``).
  var isMainWindowFront = false
  /// Bumped to open the onboarding window (the popover's connect prompt, and once at launch while nothing is saved).
  private(set) var onboardingRequest = 0
  /// Memos whose Delete is queued and has not run yet: the toolbar's Delete is off for them, and a second tap does nothing.
  private(set) var deletingIDs: Set<String> = []
  /// Bumped to open the Settings scene.
  private(set) var settingsRequest = 0
  /// The Settings tab that shows (the snapshot run switches it).
  var settingsTab = MacSettingsTab.connection
  /// Times the server came back after the stream had been down; an open detail reloads on each.
  private(set) var reconnects = 0

  let notifier: MemoNotifier
  /// The floating recording panel's state machine, and the controller that shows the panel for it.
  let recording: RecordingPanelModel
  let recordingPanel: RecordingPanelController
  /// The global key that toggles a take.
  let hotkey: any TakeHotkey
  /// The stalled-upload panel: the outbox's queue, Retry now and Discard.
  let outbox: MacOutboxModel
  /// The device log (`service.name=iris-macos`) and the Mac's own records on it.
  let log: DeviceLog
  /// "Check for Updates…" and Sparkle's schedule. Nil unless the launch passed an engine (`IrisMacApp` does, outside `-IrisFakeData`),
  /// so fake runs, snapshots and tests never start an updater.
  let updater: Updater?
  private let events: MacEvents
  /// The server key of the saved connection, read by every ``HistoryModel`` the root makes: after a connection change the old model
  /// sees a different key and drops its stale answers, and a memo created on another server is not inserted (TDD §5).
  private let serverBox: ServerKeyBox
  /// The scripted engine behind ``Mode/fake``; the snapshot run feeds its levels.
  let fakeTake: FakeTakeEngine?
  /// Production only: the outbox the takes go through, and the client its uploader talks to.
  private let capture: MacCaptureStack?
  /// The outbox a typed memo goes through: the takes' own in production, one on the fake API (and fake pipeline) under
  /// `-IrisFakeData`.
  let textOutbox: OutboxService
  /// The memos that outbox created on the server, the source of what History is told at once.
  private let createdLog: CreatedMemoLog
  /// The decoded Mermaid images of every reply on screen, shared by the conversation views.
  let replyImages: ReplyImageStore
  let artifacts: ArtifactStore
  /// One composer per conversation (nil key: the New memo page), so a draft survives switching memos.
  @ObservationIgnored private var composers: [String: ComposerModel] = [:]
  /// The composer whose memo went to the outbox instead of the server: its bar says so for a few seconds.
  private(set) var queuedNote: ObjectIdentifier?
  @ObservationIgnored private var queuedTimer: Task<Void, Never>?
  /// How long the "Queued" note stays.
  @ObservationIgnored var queuedNoteDuration = Duration.seconds(4)
  private var hotkeyListening: Task<Void, Never>?
  @ObservationIgnored private var launchObserver: (any NSObjectProtocol)?
  private var createdListening: Task<Void, Never>?
  private var outboxObserving: Task<Void, Never>?
  /// Signals each `ready` of the current connection's event stream (see ``StreamTappingClient``).
  private var streamReady: AsyncStream<Void>
  /// Every memo state the current connection's event stream reports, in order (see ``StreamTappingClient``).
  private var memoStates: AsyncStream<MemoEvent>
  /// The client of the current connection. Each connection gets its own, so a task that started on the old server can never
  /// reach the new one.
  private var api: any APIClient
  private let credentials: any CredentialStore
  /// The fake server behind ``Mode/fake``; tests push events through it.
  let fakeAPI: FakeAPIClient?
  private let sampleNow: Date
  /// What ``windowHistory`` talks to: the connection's client without the stream tap (its events come mirrored, below).
  private var baseAPI: any APIClient
  /// Every event of the current connection's one stream, mirrored for the main window's list.
  private var windowEvents: AsyncStream<ServerEvent>
  /// The detail pane's model (see ``detailModel(for:)``).
  @ObservationIgnored private var detailCache: MacMemoDetailModel?
  /// The popover's quick answer: the memo its quick-ask line just created, followed live. Nil until a question is asked.
  private(set) var quickAnswer: MacMemoDetailModel?
  @ObservationIgnored private var quickAnswerFollowing: Task<Void, Never>?
  /// The main window is on screen: its list takes the mirrored events.
  private var isWindowOpen = false
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
    hotkey: (any TakeHotkey)? = nil,
    log deviceLog: DeviceLog? = nil,
    updateEngine: (any UpdateEngine)? = nil
  ) {
    updater = updateEngine.map(Updater.init(engine:))
    sampleNow = SampleData.now(arguments: arguments)
    let client: any APIClient
    let isFakeLaunch = arguments.contains(Self.fakeDataArgument)
    let store = credentials ?? (isFakeLaunch ? InMemoryCredentialStore() : KeychainCredentialStore())
    log = deviceLog ?? MacTelemetry.makeDeviceLog(fake: isFakeLaunch, credentials: store)
    events = MacEvents(log: log)
    let serverBox = ServerKeyBox(store.load()?.serverKey)
    self.serverBox = serverBox
    if isFakeLaunch {
      let launched = Date()
      let pinned = sampleNow
      let fake = FakeAPIClient(now: { pinned.addingTimeInterval(Date().timeIntervalSince(launched)) })
      mode = .fake
      client = fake
      fakeAPI = fake
      self.credentials = store
      capture = nil
      // A typed memo goes create -> acted -> notified with the fake reply, through an outbox of its own (no microphone, no disk).
      let fakeCreated = CreatedMemoLog()
      createdLog = fakeCreated
      textOutbox = Self.fakeOutbox(
        client: fake, created: fakeCreated, log: log, step: Self.fakePipelineStep(arguments))
      replyImages = ReplyImageStore(
        loader: MediaAssetLoader(source: { FakeMediaSource() }, downloader: .shared))
      artifacts = ArtifactStore(
        loader: MediaAssetLoader(source: { FakeMediaSource() }, downloader: .shared))
    } else {
      let saved = store.load()
      let reconfigurable = ReconfigurableAPIClient(credentials: saved)
      mode = .production
      client = reconfigurable
      fakeAPI = nil
      self.credentials = store
      let stack = MacCaptureStack.production(credentials: saved, log: log)
      capture = stack
      createdLog = stack.created
      textOutbox = stack.service
      replyImages = ReplyImageStore(
        loader: MediaAssetLoader(
          source: {
            guard let saved = store.load() else { return UnavailableMediaSource() }
            return AuthenticatedMediaSource(baseURL: saved.serverURL, bearerToken: saved.token)
          }, downloader: .shared))
      artifacts = ArtifactStore(
        loader: MediaAssetLoader(
          source: {
            guard let saved = store.load() else { return UnavailableMediaSource() }
            return AuthenticatedMediaSource(baseURL: saved.serverURL, bearerToken: saved.token)
          }, downloader: .shared))
    }
    let tap = TappedConnection(base: client)
    streamReady = tap.ready
    memoStates = tap.states
    windowEvents = tap.events
    let tapped = tap.client
    api = tapped
    baseAPI = client
    history = Self.makeHistory(client: tapped, mode: mode, serverBox: serverBox)
    windowHistory = Self.makeHistory(client: client, mode: mode, serverBox: serverBox)
    let isFake = mode == .fake
    notifier = MemoNotifier(
      poster: poster ?? (isFake ? RecordingNotificationPoster() : UserNotificationPoster()),
      connectionID: Self.connectionID(for: isFake ? nil : self.credentials.load()), lookup: { _ in nil })
    let engine: any TakeEngine = takeEngine ?? capture?.engine ?? FakeTakeEngine()
    fakeTake = engine as? FakeTakeEngine
    recording = RecordingPanelModel(
      engine: engine, permission: permission ?? (isFake ? FakeMicrophonePermission() : SystemMicrophonePermission()),
      isConfigured: { isFake || store.load() != nil })
    let takeHotkey: any TakeHotkey = hotkey ?? (isFake ? FakeTakeHotkey() : KeyboardShortcutsHotkey())
    recordingPanel = RecordingPanelController(model: recording, shortcut: { takeHotkey.shortcutDescription })
    let queue: any QueuedItemSource
    if let capture {
      queue = capture.service
    } else {
      queue = ScriptedQueue(arguments.contains(Self.stalledArgument) ? ScriptedQueue.stalledSample : [])
    }
    outbox = MacOutboxModel(source: queue)
    self.hotkey = takeHotkey
    // Always fetched: the list's copy can be stale, and a failed refresh must not announce a memo that is still running.
    notifier.lookup = { [weak self] id in try? await self?.api.memo(id: id).memo }
    // The catch-up reads the newest memos with no filter: History's filters decide what its list shows, not what is announced.
    notifier.fetchRecent = { [weak self] in
      guard let page = try? await self?.api.listMemos(ListMemosQuery(limit: 50)) else { return nil }
      return page.items
    }
    wireCreatedMemos()
    wireTelemetry()
  }

  /// The Mac's take, panel, banners and queue actions on the device log. Every record is an enum or a count: nothing a person
  /// said, nothing a server answered, no token, URL or device id.
  private func wireTelemetry() {
    let log = log
    let events = events
    recording.onCommand = { log.commandSource = $0 }
    recording.onPhaseChange = { events.panel(phase: $0.telemetryName, failure: $0.telemetryFailure) }
    notifier.report = { event in
      switch event {
      case .posted(let id, let kind): events.notification("posted", memoID: id, kind: kind.telemetryName)
      case .withdrawn(let id, let kind): events.notification("withdrawn", memoID: id, kind: kind.telemetryName)
      case .caughtUp(let announced, let seen):
        events.notification("catchup", memoID: nil, kind: nil, count: announced, seen: seen)
      }
    }
    outbox.report = { action, item, ok in
      events.outboxAction(action, memoID: item.id, kind: item.kind.telemetryName, ok: ok)
    }
  }

  /// Starts the relay (production only: the fake composition keeps its records in memory) and records the launch.
  func startTelemetry() {
    log.commandSource = "panel"
    events.lifecycle(.launch)
    guard mode == .production else { return }
    log.start()
    // Delivered on the main queue, so the main actor is where this runs.
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main)
    {
      [events] _ in
      MainActor.assumeIsolated { events.lifecycle(.quit) }
    }
  }

  private static func makeHistory(client: any APIClient, mode: Mode, serverBox: ServerKeyBox) -> HistoryModel {
    // The key is given explicitly: the client is wrapped (`StreamTappingClient`), so the model cannot read it from the client.
    let serverKey: () -> String? = { serverBox.value }
    return mode == .fake
      ? HistoryModel(client: client, serverKey: serverKey)
      : HistoryModel(client: client, hiddenStore: UserDefaultsHiddenMemoStore(), serverKey: serverKey)
  }

  /// What the outbox tells History, in the order it happened.
  private enum CreatedChange: Sendable {
    /// `origin` is the server key the memo was created on (nil: the item was bound to none).
    case created(Memo, origin: String?)
    /// A cancelled take: its memo is dropped and stays out of the list until its server `DELETE` settles.
    case hide(String)
    case unhide(String)
  }

  /// A memo the outbox created on the server shows in History at once, before the event stream has told the list; a cancelled
  /// take's memo goes from it at once and stays out until the server `DELETE` has settled (the iPhone's hide/settle lifecycle).
  /// One stream, one consumer: a discard and its delete settling reach History in the order they happened.
  private func wireCreatedMemos() {
    let created = createdLog
    let (changes, changed) = AsyncStream.makeStream(of: CreatedChange.self)
    // Owned by the root, which lives as long as the app. Reads `history` per change: the model of the current connection.
    createdListening = Task { [weak self] in
      for await change in changes {
        // Both lists: the popover's and the main window's.
        guard let lists = self.map({ [$0.history, $0.windowHistory] }) else { return }
        for history in lists {
          switch change {
          case .created(let memo, let origin): history.insert(memo, origin: origin)
          case .hide(let id): history.hide(id)
          case .unhide(let id): history.unhide(id)
          }
        }
      }
    }
    Task {
      await created.setServerHandler { changed.yield(.created($0, origin: $1)) }
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
      for await _ in presses {
        self?.events.hotkey()
        self?.recording.toggle(threadID: self?.frontConversationThreadID)
      }
    }
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
  /// server sees; a later action looks the memo up again when it runs (see ``MacMemoRow``), it does not act on a copy from tap time.
  func perform(
    on model: HistoryModel, memoID: String? = nil, _ action: @escaping @MainActor (HistoryModel) async -> Void
  ) {
    let revision = connectionRevision
    let previous = memoID.flatMap { queues[$0]?.task }
    let token = UUID()
    let task = Task { [weak self] in
      await previous?.value
      guard let self, revision == connectionRevision, model === history || model === windowHistory else { return }
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
  /// Fakes: the outbox panel starts with a stalled upload, a waiting one and a queued removal (screenshots).
  static let stalledArgument = "-IrisMacStalled"
  /// Opens the popover as a regular window at launch, because a menu-bar popover cannot be opened without a click
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
    // The queue is followed for the life of the app: a take made before any connection was saved can be waiting in it.
    if outboxObserving == nil { outboxObserving = Task { [outbox] in await outbox.observe() } }
    following?.cancel()
    following = Task { [weak self] in await self?.follow() }
  }

  /// Fakes: seeds the sample memos. Then, when there is a connection: loads the list and follows `/v1/events` until cancelled.
  /// The notification prompt is shown on the side: an unanswered prompt never holds History or the stream back.
  private func follow() async {
    if let fakeAPI { await SampleData.seed(fakeAPI, now: sampleNow) }
    guard isConfigured else { return }
    let lists = [history, windowHistory]
    // Opens the outbox and sends what an earlier run left in it (a take made offline, or cut short by a quit). Then the hidden
    // ids of discarded takes whose server `DELETE` is no longer queued are let go (an outbox that cannot be opened says nothing).
    Task {
      await capture?.service.resume()
      if let pending = await capture?.service.pendingDeletionIDs() {
        for list in lists { list.reconcileHidden(pendingDeletions: pending) }
      }
    }
    notifier.requestPermissionIfNeeded()
    // Banners left by an earlier run or an earlier server do not name this one's memos.
    notifier.withdrawForeignBanners()
    // The stream does not wait for the first list request: a slow or hung list must not keep the notifications away. The stream's
    // `ready` event reloads the list on its own.
    async let list: Void = history.load()
    async let events: Void = history.observeEvents()
    async let returns: Void = countReturns(of: streamReady)
    async let states: Void = followStates(of: memoStates)
    async let window: Void = followWindow(of: windowEvents)
    _ = await (list, events, returns, states, window)
  }

  /// Every `ready` of the event stream after the first is the server coming back; an open detail reloads on it, and the
  /// notifier catches up on what finished while the stream was down (the first `ready` of a connection is its baseline).
  private func countReturns(of ready: AsyncStream<Void>) async {
    for await _ in ready {
      guard !Task.isCancelled else { return }
      reconnects += 1
      let generation = notifier.generation
      // One catch-up per `ready`, on its own task: it fetches and may post, and must not hold the next `ready` back.
      Task { [notifier] in await notifier.catchUp(generation: generation) }
    }
  }

  /// The states the stream reports, in order: a memo that reached a kind of banner it was not announced as is delivered.
  /// Noting a state is synchronous, so a later event can never be overtaken by an earlier one.
  private func followStates(of states: AsyncStream<MemoEvent>) async {
    for await event in states {
      guard !Task.isCancelled else { return }
      if notifier.noteState(of: event) { announce(event.id, with: notifier) }
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
    show(id, source: "notification")
  }

  /// Shows `id` in the main window (`source`: `menu` or `notification`, for the device log). Selects the memo and asks the menu-bar label
  /// to open (or raise) the window.
  func show(_ id: String, source: String = "menu") {
    selectedMemoID = id
    showMainWindow(source: source)
  }

  /// A fresh memo to type: the New memo page in the main window, which is opened or raised.
  func newMemo() {
    selectedMemoID = nil
    showMainWindow(source: "new-memo")
  }

  // MARK: Typed memos

  /// The composer of a conversation (`threadId`) or of the New memo page (nil). One per key, kept until the connection changes,
  /// so what was typed survives a look at another memo.
  func composer(for threadId: String?) -> ComposerModel {
    composer(key: threadId ?? "", threadId: threadId)
  }

  /// The popover's quick-ask line: a new Hermes memo with a draft of its own, apart from the New memo page's.
  var quickAskComposer: ComposerModel {
    composer(key: Self.quickAskKey, threadId: nil)
  }

  /// Not a thread id (those are UUIDs), so it never meets a conversation's composer.
  private static let quickAskKey = "quick-ask"

  private func composer(key: String, threadId: String?) -> ComposerModel {
    if let cached = composers[key] { return cached }
    let model = ComposerModel(request: ComposerRequest(threadId: threadId), outbox: textOutbox)
    composers[key] = model
    return model
  }

  /// Sends what `model` holds as a memo of `mode`. A memo the server has, or the outbox keeps for later, clears the text; a refusal
  /// leaves it with the reason in ``ComposerModel/failure``. A new memo opens in the window; a reply stays in its conversation,
  /// which shows it at once.
  func sendTyped(_ model: ComposerModel, mode: MemoMode) async {
    let revision = connectionRevision
    guard let outcome = await model.send(mode: mode), revision == connectionRevision else { return }
    switch outcome {
    case .sent(let memo):
      model.text = ""
      didSend(memo, from: model)
    case .queued:
      model.text = ""
      noteQueued(model)
    case .refused, .stalled:
      return
    }
  }

  private func didSend(_ memo: Memo, from model: ComposerModel) {
    if model === composers[Self.quickAskKey] {
      showQuickAnswer(for: memo)
      return
    }
    if let threadId = model.threadId, let open = detailCache, open.memoID == selectedMemoID,
      open.memo?.threadId == threadId
    {
      open.didSend(memo)
      return
    }
    if detailCache?.memoID != memo.id {
      detailCache = MacMemoDetailModel(
        memoID: memo.id, memo: memo, client: api, pasteboard: MacPasteboard())
    }
    selectedMemoID = memo.id
  }

  // MARK: Quick ask

  /// The memo the quick-ask line created shows in the popover with its live turn (tools, then the streaming answer), until the
  /// owner dismisses it or opens it in the window. The window's selection stays as it was.
  private func showQuickAnswer(for memo: Memo) {
    quickAnswerFollowing?.cancel()
    let answer = MacMemoDetailModel(memoID: memo.id, memo: memo, client: api, pasteboard: MacPasteboard())
    quickAnswer = answer
    let events = history.liveEvents()
    // Owned by the root; replaced by the next question, cancelled by a dismiss or a connection change.
    quickAnswerFollowing = Task {
      for await event in events { await answer.apply(event) }
    }
  }

  /// The popover goes back to the newest memos.
  func dismissQuickAnswer() {
    quickAnswerFollowing?.cancel()
    quickAnswerFollowing = nil
    quickAnswer = nil
  }

  /// "Open in window": the question and its answer continue in the main window.
  func openQuickAnswerInWindow() {
    guard let id = quickAnswer?.memoID else { return }
    dismissQuickAnswer()
    show(id, source: "quick-ask")
  }

  // MARK: Voice

  /// The composer's microphone: a Hermes take; in a conversation (`threadID`) the memo continues it.
  func talk(in threadID: String?) {
    recording.toggle(mode: .hermes, threadID: threadID)
  }

  /// The conversation the global key continues: the one open in the main window while that window is the key window. Nil
  /// otherwise (a new memo), and for a memo with no Hermes session.
  var frontConversationThreadID: String? {
    guard isMainWindowFront, let id = selectedMemoID, let open = detailCache, open.memoID == id else { return nil }
    return open.replyThreadID
  }

  // MARK: Launch

  /// Called once the system has finished launching the app. A launch by the user opens the main window (the menu bar alone looked
  /// like nothing had started); a launch at login stays in the menu bar, and a first run shows the onboarding window instead.
  func launchDidFinish(loginItem: Bool) {
    guard !loginItem, !needsOnboarding else { return }
    launchWindowPending = true
  }

  /// The label's one look at the launch: true once, when the main window is to open.
  func takeLaunchWindow() -> Bool {
    defer { launchWindowPending = false }
    if launchWindowPending { events.window("main", action: "request", source: "launch") }
    return launchWindowPending
  }

  /// Production: watches for the end of launching and reads how the app was started.
  func installLaunchDetection() {
    guard mode == .production, launchObserver == nil else { return }
    launchObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
    ) { [weak self] _ in
      // Delivered on the main queue, so the main actor is where this runs. The launch event is only current inside this call.
      let loginItem = MacLaunchOrigin.isLoginItem(NSAppleEventManager.shared().currentAppleEvent)
      MainActor.assumeIsolated { self?.launchDidFinish(loginItem: loginItem) }
    }
  }

  private func noteQueued(_ model: ComposerModel) {
    queuedTimer?.cancel()
    let id = ObjectIdentifier(model)
    queuedNote = id
    let duration = queuedNoteDuration
    // Owned by the root, replaced by the next note.
    queuedTimer = Task { [weak self] in
      guard (try? await Task.sleep(for: duration)) != nil, self?.queuedNote == id else { return }
      self?.queuedNote = nil
    }
  }

  /// How long each fake pipeline stage takes: 1.2 s, or `-IrisFakeStepMs <n>` (tests ask for a fast server).
  private static func fakePipelineStep(_ arguments: [String]) -> Duration {
    guard let index = arguments.firstIndex(of: "-IrisFakeStepMs"), arguments.indices.contains(index + 1),
      let milliseconds = Int(arguments[index + 1]), milliseconds > 0
    else { return .milliseconds(1_200) }
    return .milliseconds(milliseconds)
  }

  /// The outbox of `-IrisFakeData`: the real queue over the fake API on fake audio, and the fake pipeline walks a typed memo to
  /// `notified` with the fake reply. A slow first retry keeps a failed item visible.
  private static func fakeOutbox(
    client: FakeAPIClient, created: CreatedMemoLog, log: DeviceLog, step: Duration
  ) -> OutboxService {
    let fakeCapture = FakeCapture(
      directory: FileManager.default.temporaryDirectory.appending(path: "iris-fake-capture"))
    let stack = CaptureStack(
      .init(
        session: fakeCapture.session, routes: fakeCapture.routes, recorder: fakeCapture.recorder,
        clock: SystemCaptureClock(), store: InMemoryOutboxStore(),
        uploader: ObservedSegmentUploader(
          FakePipelineUploader(
            base: APIOutboxUploader(client: client, created: created),
            pipeline: FakePipeline(client: client, step: step)),
          log: log),
        policy: OutboxPolicy(baseDelay: 30), events: DeviceLogCaptureEvents(log: log), deletesFilesWhenDone: false))
    return OutboxService(stack: stack, created: created)
  }

  func beginDelete(_ id: String) -> Bool { deletingIDs.insert(id).inserted }
  func endDelete(_ id: String) { deletingIDs.remove(id) }

  /// Opens (or raises) the main window as it is.
  func showMainWindow(source: String = "menu") {
    windowRequest += 1
    events.window("main", action: "request", source: source)
  }

  /// A window or scene appeared or closed (`main`, `settings`, `onboarding`), for the device log.
  func noteWindow(_ name: String, _ action: String) {
    events.window(name, action: action)
  }

  /// Opens the onboarding window (the popover's connect prompt).
  func showOnboarding(source: String = "menu") {
    onboardingRequest += 1
    events.window("onboarding", action: "request", source: source)
  }

  /// Opens the Settings scene.
  func showSettings(source: String = "menu") {
    settingsRequest += 1
    events.window("settings", action: "request", source: source)
  }

  /// Nothing is saved on a real install: the app has nothing to show until the onboarding window has taken a connection.
  var needsOnboarding: Bool { mode == .production && !isConfigured }

  /// The main window is on screen: its list follows the mirrored events until ``windowDidDisappear()``. The window's own
  /// `.task(id: filters)` loads the first page; the stream's `ready` reloads it.
  func windowDidAppear() {
    isWindowOpen = true
  }

  func windowDidDisappear() {
    isWindowOpen = false
  }

  /// Hands the stream's events to the window's list while the window is open; the popover's list consumes the same events itself.
  private func followWindow(of events: AsyncStream<ServerEvent>) async {
    for await event in events {
      guard !Task.isCancelled else { return }
      guard isWindowOpen else { continue }
      await windowHistory.handle(event)
    }
  }

  /// The Mac window's media: a recording or the spoken reply downloaded with the device token (fake clips under `-IrisFakeData`).
  var mediaSource: any MemoMediaSource {
    _ = connectionRevision
    if mode == .fake { return FakeMediaSource() }
    guard let saved = credentials.load() else { return UnavailableMediaSource() }
    return AuthenticatedMediaSource(baseURL: saved.serverURL, bearerToken: saved.token)
  }

  /// Makes the main window's list hold `memo`, which it may not (a popover row or a banner opened a memo past the window's filter or
  /// loaded pages): the scope goes to All memos (Archive for an archived memo, which All hides), the search is cleared, the first
  /// page loads, and the memo is inserted into the list. Its actions resolve the memo in the list when they run, so it must be there.
  /// A load that finishes after the insert replaces the list, so the insert is repeated until it sticks (bounded).
  func ensureHeld(_ memo: Memo) async {
    guard isConfigured, !windowHistory.memos.contains(where: { $0.id == memo.id }) else { return }
    windowHistory.filters.searchText = ""
    scope = memo.archived ? .archive : .all
    await windowHistory.load()
    for _ in 0..<5 {
      guard !windowHistory.memos.contains(where: { $0.id == memo.id }) else { return }
      windowHistory.insert(memo)
      try? await Task.sleep(for: .milliseconds(100))
      while windowHistory.isLoading, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
    }
  }

  /// The model behind the detail pane for `id`: the list's copy of the memo shows at once, the first load brings the steps. One per
  /// memo, kept until another memo is asked for or the connection changes.
  func detailModel(for id: String) -> MacMemoDetailModel {
    if let cached = detailCache, cached.memoID == id { return cached }
    let model = MacMemoDetailModel(
      memoID: id, memo: (windowHistory.memos + history.memos).first { $0.id == id }, client: api,
      pasteboard: MacPasteboard())
    detailCache = model
    return model
  }

  /// The saved connection changed: everything that belongs to the old server goes (its lists, the selected memo,
  /// what was announced), the client points at the new one, and following starts over.
  private func connectionChanged() {
    following?.cancel()
    let base: any APIClient =
      fakeAPI ?? ReconfigurableAPIClient(credentials: credentials.load())
    let tap = TappedConnection(base: base)
    streamReady = tap.ready
    memoStates = tap.states
    windowEvents = tap.events
    api = tap.client
    baseAPI = base
    serverBox.value = credentials.load()?.serverKey
    history = Self.makeHistory(client: api, mode: mode, serverBox: serverBox)
    windowHistory = Self.makeHistory(client: base, mode: mode, serverBox: serverBox)
    scope?.apply(to: &windowHistory.filters)
    notifier.reset(connectionID: Self.connectionID(for: credentials.load()))
    queues = [:]
    deletingIDs = []
    detailCache = nil
    dismissQuickAnswer()
    composers = [:]
    queuedTimer?.cancel()
    queuedNote = nil
    capture?.reconnect(credentials.load())
    log.serverChanged(credentials.load()?.serverURL)
    selectedMemoID = nil
    reconnects = 0
    connectionRevision += 1
    begin()
  }
}

/// One connection's client wrapped in the stream tap, with the three streams the tap feeds: `ready` (the stream connected), the memo
/// states in order, and every event (mirrored to the main window's list). A new connection gets a new one, so nothing of the old
/// server's stream reaches the new consumers.
private struct TappedConnection {
  let client: StreamTappingClient
  let ready: AsyncStream<Void>
  let states: AsyncStream<MemoEvent>
  let events: AsyncStream<ServerEvent>

  init(base: any APIClient) {
    let (ready, readySignal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let (states, stateSignal) = AsyncStream<MemoEvent>.makeStream()
    let (events, eventSignal) = AsyncStream<ServerEvent>.makeStream()
    self.ready = ready
    self.states = states
    self.events = events
    client = StreamTappingClient(base: base, ready: readySignal, states: stateSignal, mirror: eventSignal)
  }
}

/// The fake composition's credential store: nothing touches the Keychain (an unsigned build gets `-34018` from it).
nonisolated final class InMemoryCredentialStore: CredentialStore {
  private let state = Mutex<ConnectionCredentials?>(nil)

  func load() -> ConnectionCredentials? { state.withLock { $0 } }
  func save(_ credentials: ConnectionCredentials) throws { state.withLock { $0 = credentials } }
  func clear() { state.withLock { $0 = nil } }
}

/// The server key of the saved connection, shared with every ``HistoryModel`` of the root (see ``MacCompositionRoot``).
@MainActor
final class ServerKeyBox {
  var value: String?

  init(_ value: String?) {
    self.value = value
  }
}
