import Foundation
import IrisCapture
import IrisCore
import IrisUI
import Observation

#if canImport(AVFAudio)
  import AVFAudio
#endif

/// The one place that decides which adapters the app runs on. Launch arguments are read here, once.
///
/// - `-IrisFakeCapture` (every UI test and `make run-sim`): the fake API client with sample data, silent media clips
///   and fake capture, no network and no Keychain.
/// - Otherwise: production. The server URL and device token come from the connection form in Settings (token in the
///   Keychain); every model holds one ``ReconfigurableAPIClient``, which follows the saved connection. With nothing
///   saved the app opens on Settings and loads nothing, so there is neither a crash nor a silent fake.
///
/// Capture runs through one ``CaptureStack`` (the persistent outbox and the capture session): typed memos, chat messages and
/// voice takes all go in through it, Settings reads the queue out, and the start intent records through the same session.
/// Under `-IrisFakeCapture` the stack runs on fake audio and the fake API; `-IrisFakeOffline` makes the first create call
/// of each kind fail, so a memo is queued and "retry now" sends it.
/// What `CreatedMemoLog` tells History about a discarded memo, in the order it happened.
private enum HiddenChange: Sendable {
  case hide(String)
  case unhide(String)
}

@MainActor
@Observable
final class CompositionRoot: CaptureIntentHandler, PlaybackIntentHandler {
  enum Mode: Equatable {
    case fake
    case production
  }

  let mode: Mode
  /// The clock the fake sample memos are relative to: the real one, or the one a UI test pinned (`-IrisSampleNow`).
  private let sampleNow: Date
  /// Production with nothing saved at launch: the app opens on Settings.
  let opensOnSettings: Bool
  let fakeCapture: FakeCapture?
  let history: HistoryModel
  let stats: StatsModel
  let settings: SettingsModel
  let diagnostics: DiagnosticsModel
  /// The microphone rule of the active audio route (Settings).
  let micRules: MicRulesModel
  /// The spoken-replies setting and the reader of finished replies.
  let spokenReplies: SpokenReplies
  /// The app's one spoken-reply player: the detail's Play, `PlayReplyIntent` and spoken replies.
  let speech = SpeechPlayer()
  /// The queue of whole memos and messages: submissions go in here, Settings reads it.
  let outbox: OutboxService
  /// The take in progress, for the take screen, the banner and the record control.
  let take: TakeModel
  /// The Live Activity requests of takes the app starts on its own; the tests read the fake's record.
  let fakeLiveActivity: RecordingLiveActivity?
  /// The decoded images of every reply on screen (Mermaid diagrams), shared by all thread screens.
  let replyImages: ReplyImageStore
  /// The editable connection; nil when running on fakes.
  private(set) var connectionForm: ConnectionModel?
  /// Bumped when the saved connection changes; `IrisApp` restarts ``start()`` on it.
  private(set) var connectionRevision = 0

  private let api: any APIClient
  let fakeAPI: FakeAPIClient?
  private let credentials: (any CredentialStore)?
  private let reconfigurable: ReconfigurableAPIClient?
  private let voiceReply: any VoiceReplyCapture
  private let liveActivity: TakeLiveActivityCoordinator
  private let takeController: TakeController
  private let simulatesOffline: Bool

  init(
    arguments: [String] = ProcessInfo.processInfo.arguments,
    credentials: any CredentialStore = KeychainCredentialStore()
  ) {
    let diagnostics = DiagnosticsModel(pasteboard: SystemPasteboard())
    self.diagnostics = diagnostics
    let pinnedNow = SampleData.now(arguments: arguments)
    sampleNow = pinnedNow
    if FakeCapture.isRequested(arguments: arguments) {
      // The fake server's clock starts at the sample clock and runs from there, so a memo created in the app is newer than the
      // samples whatever instant they were pinned to.
      let launched = Date()
      let fake = FakeAPIClient(now: { pinnedNow.addingTimeInterval(Date().timeIntervalSince(launched)) })
      mode = .fake
      opensOnSettings = false
      api = fake
      fakeAPI = fake
      self.credentials = nil
      reconfigurable = nil
      let capture = FakeCapture(directory: FileManager.default.temporaryDirectory.appending(path: "iris-fake-capture"))
      fakeCapture = capture
      let created = CreatedMemoLog()
      // `-IrisFakeUnreadableOutbox`: a saved queue that cannot be decoded, for the Settings reset row.
      let fakeStore: any OutboxStore =
        arguments.contains("-IrisFakeUnreadableOutbox") ? UnreadableOutboxStore() : InMemoryOutboxStore()
      let stack = CaptureStack(
        .init(
          session: capture.session, routes: capture.routes, recorder: capture.recorder, clock: SystemCaptureClock(),
          store: fakeStore,
          uploader: FakePipelineUploader(
            base: APIOutboxUploader(client: fake, created: created),
            pipeline: FakePipeline(client: fake, step: Self.fakePipelineStep(arguments))),
          // A slow first retry: a queued item stays visible until "retry now", whatever the speed of the test runner.
          policy: OutboxPolicy(baseDelay: 30), deletesFilesWhenDone: false))
      let service = OutboxService(stack: stack, created: created)
      outbox = service
      micRules = MicRulesModel(routes: stack.routes)
      let mic = FakeMicrophone(capture: capture)
      simulatesOffline = arguments.contains("-IrisFakeOffline")
      let recording = RecordingLiveActivity()
      fakeLiveActivity = recording
      let coordinator = TakeLiveActivityCoordinator(activity: recording, stack: stack, created: created)
      liveActivity = coordinator
      takeController = TakeController(
        stack: stack, liveActivity: coordinator, outbox: service, microphone: mic, canRecord: true,
        isConfigured: { true }, requestPermission: { true })
      history = HistoryModel(client: fake, evictMedia: { MediaDownloader.shared.evict(memoID: $0) })
      stats = StatsModel(client: fake)
      settings = SettingsModel(client: fake, queue: service)
      replyImages = ReplyImageStore(
        loader: MediaAssetLoader(source: { FakeMediaSource() }, downloader: .shared))
      voiceReply = OutboxVoiceReplyCapture(
        stack: stack, service: service, onBegan: { mic.start() }, willEnd: { await mic.stop() })
      take = TakeModel(controller: takeController)
    } else {
      let saved = credentials.load()
      let client = ReconfigurableAPIClient(credentials: saved)
      mode = .production
      opensOnSettings = saved == nil
      api = client
      fakeAPI = nil
      self.credentials = credentials
      reconfigurable = client
      let created = CreatedMemoLog()
      let production = Self.productionStack(client: client, created: created)
      let service = OutboxService(stack: production.stack, created: created)
      outbox = service
      micRules = MicRulesModel(routes: production.stack.routes)
      simulatesOffline = false
      fakeLiveActivity = nil
      let coordinator = TakeLiveActivityCoordinator(
        activity: ActivityKitTakeLiveActivity(client: client), stack: production.stack, created: created)
      liveActivity = coordinator
      takeController = TakeController(
        stack: production.stack, liveActivity: coordinator, outbox: service, microphone: nil,
        canRecord: production.canRecord, isConfigured: { credentials.load() != nil },
        requestPermission: { await AVAudioApplication.requestRecordPermission() })
      history = HistoryModel(
        client: client, hiddenStore: UserDefaultsHiddenMemoStore(),
        evictMedia: { MediaDownloader.shared.evict(memoID: $0) })
      stats = StatsModel(client: client)
      settings = SettingsModel(client: client, queue: service, credentials: credentials)
      fakeCapture = nil
      voiceReply = OutboxVoiceReplyCapture(
        stack: production.stack, service: service, isAvailable: production.canRecord,
        requestPermission: { await AVAudioApplication.requestRecordPermission() })
      replyImages = ReplyImageStore(
        loader: MediaAssetLoader(
          source: { Self.mediaSource(for: credentials.load()) }, downloader: .shared))
      take = TakeModel(controller: takeController)
    }
    let outbox = outbox
    let fake = mode == .fake
    let saved = self.credentials
    let reader = SpokenReplies(
      store: fake ? InMemorySpokenRepliesStore() : UserDefaultsSpokenRepliesStore(), speech: speech, client: api,
      media: { fake ? FakeMediaSource() : Self.mediaSource(for: saved?.load()) },
      createdHere: { await outbox.created.memo(id: $0) != nil })
    spokenReplies = reader
    history.onMemoDone = { id in Task { await reader.memoDone(id: id) } }
    CaptureIntents.handler = self
    PlaybackIntents.handler = self
    if mode == .production, let store = self.credentials {
      connectionForm = ConnectionModel(store: store) { [unowned self] in connectionChanged() }
    }
    let history = history
    // Hide and unhide of one memo must reach History in the order they happened (a discard, then its delete settling): one
    // stream, one consumer, instead of a task per call.
    let (hiddenChanges, hiddenChanged) = AsyncStream.makeStream(of: HiddenChange.self)
    Task {
      for await change in hiddenChanges {
        switch change {
        case .hide(let id): history.hide(id)
        case .unhide(let id): history.unhide(id)
        }
      }
    }
    Task {
      await outbox.created.setHandler { memo in Task { @MainActor in history.insert(memo) } }
      await outbox.created.setForgottenHandler { id in hiddenChanged.yield(.hide(id)) }
      await outbox.created.setSettledHandler { id in hiddenChanged.yield(.unhide(id)) }
    }
  }

  /// How long each fake pipeline stage takes: 1.2 s, or `-IrisFakeStepMs <n>` (a UI test that must catch the pending turn
  /// before the answer replaces it asks for a slower server).
  private static func fakePipelineStep(_ arguments: [String]) -> Duration {
    guard let index = arguments.firstIndex(of: "-IrisFakeStepMs"), arguments.indices.contains(index + 1),
      let milliseconds = Int(arguments[index + 1]), milliseconds > 0
    else { return .milliseconds(1_200) }
    return .milliseconds(milliseconds)
  }

  /// A server URL and token are saved (always true on fakes). Reads `connectionRevision`, so a view that shows this
  /// follows the connection form's saves.
  var isConfigured: Bool {
    _ = connectionRevision
    return credentials?.load() != nil || mode == .fake
  }

  /// The model behind one open memo detail.
  func detailModel(for memo: Memo) -> MemoDetailModel {
    MemoDetailModel(memo: memo, client: api, media: mediaSource(), speech: speech)
  }

  /// The model behind one open composer sheet.
  func composerModel(for request: ComposerRequest) -> ComposerModel {
    ComposerModel(request: request, outbox: outbox)
  }

  /// The model behind one route sheet. A 409 (somebody answered first) refreshes the list.
  func routeAnswerModel(for memo: Memo) -> RouteAnswerModel {
    let history = history
    return RouteAnswerModel(memo: memo, client: api, onStale: { Task { await history.load() } })
  }

  /// The model behind one open conversation.
  func threadModel(for route: ThreadRoute) -> ThreadModel {
    ThreadModel(route: route, client: api, voice: voiceReply)
  }

  /// Fakes: seeds the sample memos. Then, when there is a connection: loads the list and follows the server's events
  /// until the app's task is cancelled. After a connection change Settings and Stats reload too.
  func start() async {
    if simulatesOffline, let fakeAPI {
      for endpoint in [FakeAPIClient.Endpoint.createTextMemo, .createMemo] {
        await fakeAPI.enqueueFailure(.transport(.notConnectedToInternet), for: endpoint)
      }
    }
    if let fakeAPI { await SampleData.seed(fakeAPI, now: sampleNow) }
    guard isConfigured else { return }
    // Loads the saved queue and sends what is due: items left over from the last session, or from before a connection change.
    await outbox.resume()
    // An outbox that cannot be opened says nothing about its deletes: the persisted hidden ids are left as they are.
    if let pending = await outbox.pendingDeletionIDs() { history.reconcileHidden(pendingDeletions: pending) }
    // A take's Live Activity does not outlive its process: end the ones the last run left in a client phase.
    await liveActivity.endOrphans()
    if connectionRevision > 0 {
      await settings.load()
      await stats.load()
    }
    await history.load()
    await history.observeEvents()
  }

  // MARK: CaptureIntentHandler

  /// Starts a take in `auto` mode with its Live Activity: what the Control, Siri and the Shortcuts app run.
  func startMemo() async throws {
    try await takeController.start(mode: .auto)
  }

  /// Ends the take and sends it: the Live Activity's Stop.
  func endTake() async throws {
    _ = try await takeController.stop()
  }

  func toggleTakePause() async {
    await takeController.togglePause()
  }

  func switchTakeInput() async throws {
    try await takeController.switchToNextInput()
  }

  /// Ends the take the intent started: the memo is finished in the outbox. `nil` when there is none, or nothing was said.
  @discardableResult
  func stopMemo() async throws -> TakeResult? {
    try await takeController.stop()
  }

  // MARK: PlaybackIntentHandler

  /// Speaks the reply of `memoID` (the Play intent): the memo is fetched fresh, so a reply that finished while the app was
  /// away is there.
  func playReply(memoID: String) async throws {
    let memo = try await api.memo(id: memoID).memo
    guard memo.hasReply, !memo.isDeleted else { throw PlayReplyError.noReply }
    guard await speech.play(memo, source: mediaSource()) else { throw PlayReplyError.busy }
  }

  /// The media routes for the connection saved right now, so a detail opened after a change uses the new token.
  private func mediaSource() -> any MemoMediaSource {
    switch mode {
    case .fake: FakeMediaSource()
    case .production: Self.mediaSource(for: credentials?.load())
    }
  }

  private static func mediaSource(for saved: ConnectionCredentials?) -> any MemoMediaSource {
    saved.map { AuthenticatedMediaSource(baseURL: $0.serverURL, bearerToken: $0.token) } ?? UnavailableMediaSource()
  }

  /// The app came to the foreground: what waited out a backoff while it was away is tried now. Fakes keep their queue as
  /// it is (a UI test reads a queued item).
  func foregrounded() async {
    guard mode == .production, isConfigured else { return }
    await outbox.resume()
  }

  private func connectionChanged() {
    reconfigurable?.reconfigure(credentials?.load())
    connectionRevision += 1
  }

  /// The real recorder, session and route manager, with the queue and the segment files in Application Support.
  private static func productionStack(
    client: any APIClient, created: CreatedMemoLog
  ) -> (stack: CaptureStack, canRecord: Bool) {
    let root = URL.applicationSupportDirectory.appending(path: "Iris", directoryHint: .isDirectory)
    let captureDirectory = root.appending(path: "capture", directoryHint: .isDirectory)
    let recorder = try? AVAudioEngineSegmentRecorder(directory: captureDirectory)
    let stack = CaptureStack(
      .init(
        session: AVAudioSessionController(), routes: AVAudioSessionRouteManager(),
        recorder: recorder ?? UnavailableSegmentRecorder(), clock: SystemCaptureClock(),
        store: JSONFileOutboxStore(fileURL: root.appending(path: "outbox.json")),
        uploader: APIOutboxUploader(client: client, created: created), captureDirectory: captureDirectory))
    return (stack, recorder != nil)
  }
}
