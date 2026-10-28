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
@MainActor
@Observable
final class CompositionRoot: CaptureIntentHandler {
  enum Mode: Equatable {
    case fake
    case production
  }

  let mode: Mode
  /// Production with nothing saved at launch: the app opens on Settings.
  let opensOnSettings: Bool
  let fakeCapture: FakeCapture?
  let history: HistoryModel
  let stats: StatsModel
  let settings: SettingsModel
  let diagnostics: DiagnosticsModel
  /// The queue of whole memos and messages: submissions go in here, Settings reads it.
  let outbox: OutboxService
  /// The Live Activity requests of takes the app starts on its own; the tests read the fake's record.
  let fakeLiveActivity: RecordingLiveActivity?
  /// The decoded images of every reply on screen (Mermaid diagrams), shared by all thread screens.
  let replyImages: ReplyImageStore
  /// The editable connection; nil when running on fakes.
  private(set) var connectionForm: ConnectionModel?
  /// Bumped when the saved connection changes; `IrisApp` restarts ``start()`` on it.
  private(set) var connectionRevision = 0

  private let api: any APIClient
  private let fakeAPI: FakeAPIClient?
  private let credentials: (any CredentialStore)?
  private let reconfigurable: ReconfigurableAPIClient?
  private let voiceReply: any VoiceReplyCapture
  private let stack: CaptureStack
  private let liveActivity: TakeLiveActivityCoordinator
  private let microphone: FakeMicrophone?
  private let requestPermission: @Sendable () async -> Bool
  private let simulatesOffline: Bool

  init(
    arguments: [String] = ProcessInfo.processInfo.arguments,
    credentials: any CredentialStore = KeychainCredentialStore()
  ) {
    let diagnostics = DiagnosticsModel(pasteboard: SystemPasteboard())
    self.diagnostics = diagnostics
    if FakeCapture.isRequested(arguments: arguments) {
      let fake = FakeAPIClient()
      mode = .fake
      opensOnSettings = false
      api = fake
      fakeAPI = fake
      self.credentials = nil
      reconfigurable = nil
      let capture = FakeCapture(directory: FileManager.default.temporaryDirectory.appending(path: "iris-fake-capture"))
      fakeCapture = capture
      let created = CreatedMemoLog()
      let stack = CaptureStack(
        .init(
          session: capture.session, routes: capture.routes, recorder: capture.recorder, clock: SystemCaptureClock(),
          store: InMemoryOutboxStore(),
          uploader: FakePipelineUploader(
            base: APIOutboxUploader(client: fake, created: created), pipeline: FakePipeline(client: fake)),
          // A slow first retry: a queued item stays visible until "retry now", whatever the speed of the test runner.
          policy: OutboxPolicy(baseDelay: 30), deletesFilesWhenDone: false))
      self.stack = stack
      let service = OutboxService(stack: stack, created: created)
      outbox = service
      let mic = FakeMicrophone(capture: capture)
      microphone = mic
      requestPermission = { true }
      simulatesOffline = arguments.contains("-IrisFakeOffline")
      let recording = RecordingLiveActivity()
      fakeLiveActivity = recording
      liveActivity = TakeLiveActivityCoordinator(activity: recording, stack: stack, created: created)
      history = HistoryModel(client: fake)
      stats = StatsModel(client: fake)
      settings = SettingsModel(client: fake, queue: service)
      replyImages = ReplyImageStore(
        loader: MediaAssetLoader(source: { FakeMediaSource() }, downloader: MediaDownloader()))
      voiceReply = OutboxVoiceReplyCapture(
        stack: stack, service: service, onBegan: { mic.start() }, willEnd: { await mic.stop() })
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
      stack = production.stack
      let service = OutboxService(stack: production.stack, created: created)
      outbox = service
      microphone = nil
      requestPermission = { await AVAudioApplication.requestRecordPermission() }
      simulatesOffline = false
      fakeLiveActivity = nil
      liveActivity = TakeLiveActivityCoordinator(
        activity: ActivityKitTakeLiveActivity(client: client), stack: production.stack, created: created)
      history = HistoryModel(client: client)
      stats = StatsModel(client: client)
      settings = SettingsModel(client: client, queue: service, credentials: credentials)
      fakeCapture = nil
      voiceReply = OutboxVoiceReplyCapture(
        stack: production.stack, service: service, isAvailable: production.canRecord,
        requestPermission: { await AVAudioApplication.requestRecordPermission() })
      replyImages = ReplyImageStore(
        loader: MediaAssetLoader(
          source: { Self.mediaSource(for: credentials.load()) }, downloader: MediaDownloader()))
      connectionForm = ConnectionModel(store: credentials) { [unowned self] in connectionChanged() }
    }
    CaptureIntents.handler = self
    let history = history
    Task { await outbox.created.setHandler { memo in Task { @MainActor in history.insert(memo) } } }
  }

  /// A server URL and token are saved (always true on fakes).
  var isConfigured: Bool { credentials?.load() != nil || mode == .fake }

  /// The model behind one open memo detail.
  func detailModel(for memo: Memo) -> MemoDetailModel {
    MemoDetailModel(memo: memo, client: api, media: mediaSource())
  }

  /// The model behind one open composer sheet.
  func composerModel(for request: ComposerRequest) -> ComposerModel {
    ComposerModel(request: request, outbox: outbox)
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
    if let fakeAPI { await SampleData.seed(fakeAPI) }
    guard isConfigured else { return }
    // Loads the saved queue and sends what is due: items left over from the last session, or from before a connection change.
    await outbox.resume()
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
    guard isConfigured else { throw StartMemoError.notConfigured }
    guard await requestPermission() else { throw StartMemoError.microphoneDenied }
    guard let session = try? await stack.session() else { throw StartMemoError.queueUnavailable }
    let request = TakeRequest(
      mode: MemoMode.auto.rawValue, title: String(localized: "Voice memo", comment: "Outbox row of a recorded memo"))
    let id = try await session.start(request)
    microphone?.start()
    let startedAt = await session.current.startedAt ?? Date()
    await liveActivity.begin(memoID: id, mode: .auto, startedAt: startedAt)
  }

  /// Ends the take the intent started: the memo is finished in the outbox. `nil` when there is none, or nothing was said.
  @discardableResult
  func stopMemo() async throws -> TakeResult? {
    await microphone?.stop()
    return try await stack.session().stop()
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

  private func connectionChanged() {
    reconfigurable?.reconfigure(credentials?.load())
    connectionRevision += 1
  }

  /// The real recorder, session and route manager, with the queue and the segment files in Application Support.
  private static func productionStack(
    client: any APIClient, created: CreatedMemoLog
  ) -> (stack: CaptureStack, canRecord: Bool) {
    let root = URL.applicationSupportDirectory.appending(path: "Iris", directoryHint: .isDirectory)
    let recorder = try? AVAudioEngineSegmentRecorder(
      directory: root.appending(path: "capture", directoryHint: .isDirectory))
    let stack = CaptureStack(
      .init(
        session: AVAudioSessionController(), routes: AVAudioSessionRouteManager(),
        recorder: recorder ?? UnavailableSegmentRecorder(), clock: SystemCaptureClock(),
        store: JSONFileOutboxStore(fileURL: root.appending(path: "outbox.json")),
        uploader: APIOutboxUploader(client: client, created: created)))
    return (stack, recorder != nil)
  }
}
