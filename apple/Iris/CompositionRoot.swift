import Foundation
import IrisCapture
import IrisCore
import IrisUI
import IrisTelemetry
import Observation
import UIKit

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
/// Capture runs through one ``CaptureStack`` (the persistent outbox and the capture session): typed memos and
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
  /// Deep links, notification taps and Live Activity buttons that open a conversation.
  let router = ConversationRouter()
  /// The conversation on screen, for the foreground notification decision.
  let presence = ConversationPresence()
  /// The Live Activity requests of takes the app starts on its own; the tests read the fake's record.
  let fakeLiveActivity: RecordingLiveActivity?
  /// The decoded images of every reply on screen (Mermaid diagrams), shared by all thread screens.
  let replyImages: ReplyImageStore
  let artifacts: ArtifactStore
  /// Typed replies held for a first memo's thread, kept past the life of their screen.
  let heldReplies: HeldReplyQueue
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
  let takeController: TakeController
  private let simulatesOffline: Bool
  /// `-IrisOpenURL iris://memo/<id>` (fakes only, UI tests): opened once the sample memos are seeded, as a link would be.
  private var launchLink: ConversationLink?
  /// Whether the app is in the foreground and running; the tests set it.
  @ObservationIgnored var isAppActive: @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }

  init(
    arguments: [String] = ProcessInfo.processInfo.arguments,
    credentials: any CredentialStore = KeychainCredentialStore()
  ) {
    let log = DeviceLog.shared
    let diagnostics = DiagnosticsModel(
      pasteboard: SystemPasteboard(), runID: log.runID, onRunIDChange: { log.setRunID($0) })
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
      launchLink = arguments.firstIndex(of: "-IrisOpenURL")
        .flatMap { arguments.indices.contains($0 + 1) ? URL(string: arguments[$0 + 1]) : nil }
        .flatMap { ConversationLink(url: $0) }
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
          uploader: ObservedSegmentUploader(
            FakePipelineUploader(
              base: APIOutboxUploader(client: fake, created: created),
              pipeline: FakePipeline(client: fake, step: Self.fakePipelineStep(arguments)))),
          // A slow first retry: a queued item stays visible until "retry now", whatever the speed of the test runner.
          policy: OutboxPolicy(baseDelay: 30), events: DeviceLogCaptureEvents(), deletesFilesWhenDone: false))
      let service = OutboxService(stack: stack, created: created)
      outbox = service
      micRules = MicRulesModel(routes: stack.routes)
      let mic = FakeMicrophone(capture: capture)
      simulatesOffline = arguments.contains("-IrisFakeOffline")
      let recording = RecordingLiveActivity()
      fakeLiveActivity = recording
      let coordinator = TakeLiveActivityCoordinator(
        activity: ObservedTakeLiveActivity(recording), stack: stack, created: created)
      liveActivity = coordinator
      takeController = TakeController(
        stack: stack, liveActivity: coordinator, outbox: service, microphone: mic, canRecord: true,
        isConfigured: { true }, requestPermission: { true }, speech: speech, preview: .fake(tap: capture.recorder))
      history = HistoryModel(client: fake, evictMedia: { MediaDownloader.shared.evict(memoID: $0) })
      stats = StatsModel(client: fake)
      settings = SettingsModel(client: fake, queue: service)
      replyImages = ReplyImageStore(
        loader: MediaAssetLoader(source: { FakeMediaSource() }, downloader: .shared))
      artifacts = ArtifactStore(
        loader: MediaAssetLoader(source: { FakeMediaSource() }, downloader: .shared))
      voiceReply = OutboxVoiceReplyCapture(
        stack: stack, service: service, claim: { [takeController] in takeController.claimCapture() },
        release: { [takeController] in await takeController.releaseCapture($0) }, onBegan: { mic.start() },
        willEnd: { await mic.stop() })
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
        activity: ActivityKitTakeLiveActivity(
          client: client, serverKey: { credentials.load()?.serverKey },
          isForeground: { UIApplication.shared.applicationState == .active }),
        stack: production.stack, created: created)
      liveActivity = coordinator
      takeController = TakeController(
        stack: production.stack, liveActivity: coordinator, outbox: service, microphone: nil,
        canRecord: production.canRecord, isConfigured: { credentials.load() != nil },
        requestPermission: { await AVAudioApplication.requestRecordPermission() }, speech: speech,
        preview: production.preview)
      history = HistoryModel(
        client: client, hiddenStore: UserDefaultsHiddenMemoStore(),
        evictMedia: { MediaDownloader.shared.evict(memoID: $0) })
      stats = StatsModel(client: client)
      settings = SettingsModel(client: client, queue: service, credentials: credentials)
      fakeCapture = nil
      voiceReply = OutboxVoiceReplyCapture(
        stack: production.stack, service: service, isAvailable: production.canRecord,
        requestPermission: { await AVAudioApplication.requestRecordPermission() },
        claim: { [takeController] in takeController.claimCapture() },
        release: { [takeController] in await takeController.releaseCapture($0) })
      replyImages = ReplyImageStore(
        loader: MediaAssetLoader(
          source: { Self.mediaSource(for: credentials.load()) }, downloader: .shared))
      artifacts = ArtifactStore(
        loader: MediaAssetLoader(
          source: { Self.mediaSource(for: credentials.load()) }, downloader: .shared))
      take = TakeModel(controller: takeController)
    }
    let outbox = outbox
    let queue = HeldReplyQueue(client: api, sendText: Self.typedReplySender(outbox: outbox))
    heldReplies = queue
    let fake = mode == .fake
    let saved = self.credentials
    // Every playback start reads the take controller's capture flag at the moment it starts. Weak: the controller owns the
    // player, not the other way round.
    speech.captureActive = { [weak controller = takeController] in controller?.captureActive ?? false }
    speech.player.captureActive = speech.captureActive
    let reader = SpokenReplies(
      store: fake ? InMemorySpokenRepliesStore() : UserDefaultsSpokenRepliesStore(), speech: speech, client: api,
      media: { fake ? FakeMediaSource() : Self.mediaSource(for: saved?.load()) },
      createdHere: { await outbox.created.memo(id: $0) != nil },
      takes: { [take] in TakeActivity(isOpen: take.isCapturing, started: take.takesStarted) })
    spokenReplies = reader
    history.onMemoUpdated = { id in reader.memoUpdated(id: id) }
    history.onMemoDone = { id in
      // Sampled here, on the event, not after the task hop: a take that opens in between still blocks the reply.
      let takes = reader.consumeSample(id: id)
      Task { await reader.memoDone(id: id, takes: takes) }
    }
    CaptureIntents.handler = self
    PlaybackIntents.handler = self
    if mode == .production, let store = self.credentials {
      connectionForm = ConnectionModel(store: store) { [unowned self] in connectionChanged() }
    }
    let history = history
    queue.onSent = { history.insert($0) }
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
      // The hand-off hops to the main actor, and the connection can switch meanwhile: `insert` compares the memo's server with the
      // one History reads when it runs.
      await outbox.created.setServerHandler { memo, origin in
        Task { @MainActor in history.insert(memo, origin: origin) }
      }
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
    // UI tests hold the "Copied" confirmation (`-IrisCopiedSeconds 600`) so no query races the timer on a slow runner.
    let held = UserDefaults.standard.double(forKey: "IrisCopiedSeconds")
    return MemoDetailModel(
      memo: memo, client: api, media: mediaSource(), speech: speech,
      copiedDuration: held > 0 ? .seconds(held) : .seconds(1.5))
  }

  /// The model behind one open composer sheet.
  func composerModel(for request: ComposerRequest) -> ComposerModel {
    ComposerModel(request: request, outbox: outbox)
  }

  /// The model behind one open conversation, anchored at the memo History opened. A typed reply goes through the composer's
  /// path (the outbox), so there is no second way to create a memo.
  func threadModel(for memo: Memo) -> ThreadModel {
    ThreadModel(
      memo: memo, client: api, voice: voiceReply, sendText: Self.typedReplySender(outbox: outbox),
      heldReplies: heldReplies)
  }

  /// The typed path of a reply into a thread: the composer's, so the outbox stays the one way to create a memo.
  private static func typedReplySender(
    outbox: OutboxService
  ) -> (_ text: String, _ threadID: String) async -> TypedReplyResult {
    { text, threadID in
      let composer = ComposerModel(request: .reply(toThread: threadID), outbox: outbox)
      composer.text = text
      switch await composer.send() {
      case .sent(let memo): return .sent(memo)
      case .queued: return .queued
      case .refused, .stalled, nil: return .failed
      }
    }
  }

  /// Fakes: seeds the sample memos. Then, when there is a connection: loads the list and follows the server's events
  /// until the app's task is cancelled. After a connection change Settings and Stats reload too.
  func start() async {
    if simulatesOffline, let fakeAPI {
      for endpoint in [FakeAPIClient.Endpoint.createTextMemo, .createMemo] {
        await fakeAPI.enqueueFailure(.transport(.notConnectedToInternet), for: endpoint)
      }
    }
    if let fakeAPI {
      await SampleData.seed(fakeAPI, now: sampleNow)
      if let link = launchLink {
        launchLink = nil
        router.open(link)
      }
    }
    // Cached media that outlived its memo (deleted elsewhere, or while the app was gone) does not pile up.
    MediaDownloader.shared.sweepStale()
    guard isConfigured else {
      await logLaunchOnce()
      return
    }
    // Loads the saved queue and sends what is due: items left over from the last session, or from before a connection change.
    await outbox.resume()
    // An outbox that cannot be opened says nothing about its deletes: the persisted hidden ids are left as they are.
    if let pending = await outbox.pendingDeletionIDs() { history.reconcileHidden(pendingDeletions: pending) }
    await logLaunchOnce()
    liveActivity.snapshot(reason: "launch")
    // A take's Live Activity does not outlive its process: end the ones the last run left in a client phase. Off to the side:
    // its server lookups never hold up the list.
    let orphans = Task {
      await liveActivity.endOrphans()
      liveActivity.snapshot(reason: "launch_swept")
    }
    defer { orphans.cancel() }
    if connectionRevision > 0 {
      await settings.load()
      await stats.load()
    }
    await history.load()
    await history.observeEvents()
  }

  private var hasLoggedLaunch = false
  /// What the last `app.launch` / `outbox.state` found: the queue was open.
  private var lastOutboxState = true

  /// `app.launch`, once per process: why it started, what the last run was doing when it ended, and what the queue and the
  /// set-aside folder hold (a kill without a crash report shows as files in there).
  private func logLaunchOnce() async {
    guard !hasLoggedLaunch else { return }
    hasLoggedLaunch = true
    let aside = await outbox.setAside()
    let log = DeviceLog.shared
    var attributes = await outboxStateAttributes(aside: aside)
    attributes["launch.reason"] = .string(
      UIApplication.shared.applicationState == .background ? "background_launch" : "user")
    attributes["previous.phase"] = .string(log.previousPhase)
    attributes["previous.exit"] = "unknown"
    attributes["mode"] = .string(mode == .fake ? "fake" : "production")
    log.event("app.launch", attributes)
    // The server never hears of a file in the set-aside folder: one record each, read off the main actor.
    await log.recordQuarantine(aside.recordings + aside.queueFiles)
  }

  /// The queue as the log reports it: its state, and its item count only when it could be read.
  private func outboxStateAttributes(aside: SetAsideSummary) async -> [String: AttributeValue] {
    let available = await outbox.isAvailable()
    let unreadable = available ? false : await outbox.isUnreadable()
    let items = available ? await outbox.queuedItems().count : 0
    lastOutboxState = available
    return OutboxStateRecord.attributes(
      available: available, unreadable: unreadable, items: items, quarantined: aside.count)
  }

  /// The launch found the queue closed or unreadable: say so again when it opens, so the record that read "unavailable" is not
  /// the last word.
  private func reportOutboxRecovery() async {
    guard !lastOutboxState else { return }
    let attributes = await outboxStateAttributes(aside: await outbox.setAside())
    guard lastOutboxState else { return }
    DeviceLog.shared.event("outbox.state", attributes.merging(["reason": "recovered"]) { current, _ in current })
  }

  // MARK: CaptureIntentHandler

  /// Starts a take in `hermes` mode with its Live Activity: what the Control (`OpenRecorderIntent`, in the foreground), Siri and the
  /// Shortcuts app (`StartMemoIntent`) run. A failure is shown in the app too: the control's press must never end in silence.
  func startMemo() async throws {
    try await startTake(mode: .hermes)
  }

  /// The Transcribe control's start (`OpenTranscribeRecorderIntent`): a `transcribe` take, otherwise like ``startMemo()``.
  func startTranscribeMemo() async throws {
    try await startTake(mode: .transcribe)
  }

  /// The Shortcuts / Siri start (`StartMemoIntent`): with the app not active the Live Activity is requested before the audio
  /// session (``TakeController/start(mode:threadID:source:activityFirst:)``). The Control's `OpenRecorderIntent` and an app in the
  /// foreground start in today's order.
  func startMemoFromShortcut() async throws {
    try await startTake(mode: .hermes, fromShortcut: true)
  }

  /// The Shortcut's start after the system refused the background one and the intent continued in the foreground: today's
  /// order, with the same localized recorder errors as ``startMemoFromShortcut()``.
  func startMemoFromShortcutInForeground() async throws {
    try await startTake(mode: .hermes, fromShortcut: true, activityFirst: false)
  }

  private func startTake(mode: MemoMode, fromShortcut: Bool = false, activityFirst: Bool? = nil) async throws {
    let activityFirst = activityFirst ?? (fromShortcut && !isAppActive())
    do {
      // A conversation on top continues that thread; anywhere else this is a new memo.
      let threadID = TakeThreadBinding.threadID(for: mode, presence: presence.current)
      try await takeController.start(mode: mode, threadID: threadID, source: "intent", activityFirst: activityFirst)
    } catch StartMemoError.backgroundStartRefused {
      // The intent continues in the foreground, or shows this: the take screen has nothing to say yet.
      throw StartMemoError.backgroundStartRefused
    } catch {
      take.reportStartFailure(error)
      throw fromShortcut ? Self.startError(for: error) : error
    }
  }

  /// What a Shortcut shows for a start that failed: a recorder or audio session failure in words, anything else as it is.
  private static func startError(for error: any Error) -> any Error {
    switch error as? CaptureError {
    case .sessionFailure, .sessionRefused, .engineFailure, .recordingFailed: StartMemoError.recordingFailed
    default: error
    }
  }

  /// Reply by voice (the notification action, a `focus=voice` link): a foreground Hermes take that continues `threadID`.
  /// A failure is shown on the take model, like ``startTake(mode:fromShortcut:activityFirst:)``.
  func startReplyByVoice(threadID: String) async {
    do {
      try await takeController.start(mode: .hermes, threadID: threadID, source: "notification", activityFirst: false)
    } catch {
      take.reportStartFailure(error)
    }
  }

  /// Ends the take and sends it: the Live Activity's Stop.
  func endTake(memoID: String?) async throws {
    _ = try await takeController.stop(source: "island", ifMemo: memoID)
  }

  func toggleTakePause(memoID: String?) async {
    await takeController.togglePause(source: "island", ifMemo: memoID)
  }

  func switchTakeInput() async throws {
    try await takeController.switchToNextInput(source: "island")
  }

  /// Ends the take the intent started: the memo is finished in the outbox. `nil` when there is none, or nothing was said.
  @discardableResult
  func stopMemo() async throws -> TakeResult? {
    try await takeController.stop(source: "intent")
  }

  // MARK: PlaybackIntentHandler

  /// Speaks the reply of `memoID` (the Play intent): the memo is fetched fresh, so a reply that finished while the app was
  /// away is there.
  func playReply(memoID: String) async throws {
    let memo = try await api.memo(id: memoID).memo
    let source = mediaSource()
    guard memo.hasReply, !memo.isDeleted, source.speech(for: memo) != nil else { throw PlayReplyError.noReply }
    guard await speech.play(memo, source: source) else { throw PlayReplyError.busy }
  }

  /// The memo of a deep link that History's list does not hold (a cold launch, an old memo).
  func fetchMemo(id: String) async throws -> Memo {
    try await api.memo(id: id).memo
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
    liveActivity.snapshot(reason: "foreground")
    guard mode == .production, isConfigured else { return }
    await outbox.resume()
    await reportOutboxRecovery()
    // A follower does not poll while the app is suspended: look at the handed-over activities again.
    await liveActivity.endOrphans()
  }

  /// The app left the screen and is about to be suspended: a handed-over Live Activity nobody can move on is ended for the
  /// system to remove (a suspended app polls nothing, and a build without push never gets the server's `end`).
  func backgrounded() async {
    liveActivity.snapshot(reason: "background")
    guard mode == .production else { return }
    // Without a grace period the suspension would cut the `end` off; it needs a moment, not a service.
    let application = UIApplication.shared
    var task = UIBackgroundTaskIdentifier.invalid
    task = application.beginBackgroundTask(withName: "liveactivity.end") {
      application.endBackgroundTask(task)
    }
    await liveActivity.endUnreachable()
    if task != .invalid { application.endBackgroundTask(task) }
  }

  private func connectionChanged() {
    reconfigurable?.reconfigure(credentials?.load())
    DeviceLog.shared.serverChanged(credentials?.load()?.serverURL)
    connectionRevision += 1
  }

  /// The real recorder, session and route manager, with the queue and the segment files in Application Support.
  private static func productionStack(
    client: ReconfigurableAPIClient, created: CreatedMemoLog
  ) -> (stack: CaptureStack, canRecord: Bool, preview: LivePreviewSource?) {
    let root = URL.applicationSupportDirectory.appending(path: "Iris", directoryHint: .isDirectory)
    let captureDirectory = root.appending(path: "capture", directoryHint: .isDirectory)
    let events = DeviceLogCaptureEvents()
    let recorder = try? AVAudioEngineSegmentRecorder(directory: captureDirectory, events: events)
    let segmentFiles = DirectorySegmentFiles(directory: captureDirectory)
    let stack = CaptureStack(
      .init(
        session: AVAudioSessionController(events: events), routes: AVAudioSessionRouteManager(events: events),
        recorder: recorder ?? UnavailableSegmentRecorder(), clock: SystemCaptureClock(),
        store: JSONFileOutboxStore(fileURL: root.appending(path: "outbox.json"), segmentDirectory: captureDirectory),
        uploader: ObservedSegmentUploader(APIOutboxUploader(client: client, created: created, keeping: segmentFiles)),
        events: events, segmentFiles: segmentFiles, serverKey: { client.serverKey },
        appActivity: UIKitAppActivity()))
    return (stack, recorder != nil, recorder.map { .speech(tap: $0) })
  }
}
