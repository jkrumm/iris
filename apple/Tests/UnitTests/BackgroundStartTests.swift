import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import Iris

/// What happened, in order, across the fakes of one start.
private actor OrderLog {
  private(set) var events: [String] = []
  func add(_ event: String) { events.append(event) }
}

/// The audio session that notes its activation, over the fake that can be told to refuse it (`!int`).
private nonisolated struct OrderedSession: AudioSessionController {
  let base: FakeAudioSessionController
  let log: OrderLog

  var interruptions: AsyncStream<InterruptionEvent> { base.interruptions }
  func configure() async throws { try await base.configure() }

  func activate() async throws {
    await log.add("session.activate")
    try await base.activate()
  }

  func deactivate() async throws { try await base.deactivate() }
}

/// A recorder that cannot start the engine (`!rec`).
private nonisolated struct RefusingRecorder: SegmentRecorder {
  let base: FakeSegmentRecorder

  var events: AsyncStream<CaptureEvent> { base.events }
  var levels: AsyncStream<Float> { base.levels }

  func start(memoID: MemoID) async throws { throw CaptureError.engineFailure("the engine would not start") }
  func stop() async throws { try await base.stop() }
  func rotate(for reason: RotationReason) async { await base.rotate(for: reason) }
  func pause() async { await base.pause() }
  func resume() async { await base.resume() }
}

/// The live activity that notes its request, over the recording fake.
private final class OrderedLiveActivity: TakeLiveActivity {
  let base = RecordingLiveActivity()
  let log: OrderLog

  init(log: OrderLog) { self.log = log }

  func start(
    memoID: String, mode: MemoMode, startedAt: Date, state: LiveActivityContentState
  ) async -> LiveActivityRequestResult {
    await log.add("activity.start")
    return await base.start(memoID: memoID, mode: mode, startedAt: startedAt, state: state)
  }

  func update(memoID: String, _ state: LiveActivityContentState) async { await base.update(memoID: memoID, state) }
  func memoCreated(memoID: String) async { await base.memoCreated(memoID: memoID) }
  func handOverToServer(memoID: String) async { await base.handOverToServer(memoID: memoID) }

  func end(memoID: String, finalState: LiveActivityContentState?, dismissal: ActivityDismissal) async {
    await log.add("activity.end")
    await base.end(memoID: memoID, finalState: finalState, dismissal: dismissal)
  }

  func endClientPhaseActivities(except memoIDs: Set<String>) async {
    await base.endClientPhaseActivities(except: memoIDs)
  }

  func endStaleActivities() async { await base.endStaleActivities() }
  func endUnreachableActivities() async { await base.endUnreachableActivities() }
}

/// A take controller over the fakes, with an ordered log of the session's activation and the activity's request.
@MainActor
private struct StartRig {
  let capture: FakeCapture
  let stack: CaptureStack
  let service: OutboxService
  let activity: OrderedLiveActivity
  let order: OrderLog
  let controller: TakeController

  init(refusingRecorder: Bool = false, permission: Bool = true) {
    let order = OrderLog()
    let capture = FakeCapture(
      directory: FileManager.default.temporaryDirectory.appending(path: "iris-bg-\(UUID().uuidString)"))
    let created = CreatedMemoLog()
    let client = FakeAPIClient(now: { MemoFactory.now })
    let recorder: any SegmentRecorder = refusingRecorder ? RefusingRecorder(base: capture.recorder) : capture.recorder
    let stack = CaptureStack(
      .init(
        session: OrderedSession(base: capture.session, log: order), routes: capture.routes, recorder: recorder,
        clock: ManualClock(), store: InMemoryOutboxStore(),
        uploader: APIOutboxUploader(client: client, created: created), policy: OutboxPolicy(jitter: { 0 })))
    let service = OutboxService(stack: stack, created: created, now: { MemoFactory.now })
    let activity = OrderedLiveActivity(log: order)
    self.capture = capture
    self.stack = stack
    self.service = service
    self.activity = activity
    self.order = order
    controller = TakeController(
      stack: stack,
      liveActivity: TakeLiveActivityCoordinator(activity: activity, stack: stack, created: created),
      outbox: service, microphone: nil, canRecord: true, isConfigured: { true },
      requestPermission: { permission }, preview: nil)
  }

  /// Nothing of a failed start is left: no queue row, no card, no take, no claim on the microphone.
  func expectNothingLeft(sourceLocation: SourceLocation = #_sourceLocation) async throws {
    #expect(await service.queuedItems().isEmpty, "no outbox item", sourceLocation: sourceLocation)
    #expect(activity.base.liveIDs.isEmpty, "no activity left", sourceLocation: sourceLocation)
    #expect(try await stack.session().current.phase == .idle, sourceLocation: sourceLocation)
    #expect(!controller.captureActive, sourceLocation: sourceLocation)
  }
}

extension CaptureHandlerSuites {
  @MainActor
  @Suite("A start from the background")
  struct BackgroundStartTests {
    @Test("a background start requests the Live Activity before the session activates, for the same memo")
    func activityFirst() async throws {
      let rig = StartRig()

      let id = try await rig.controller.start(mode: .hermes, source: "intent", activityFirst: true)

      #expect(await rig.order.events == ["activity.start", "session.activate"])
      #expect(rig.activity.base.starts.map(\.memoID) == [id.wireID])
      #expect(try await rig.stack.session().current.memoID == id)
      #expect(try await rig.stack.session().current.phase == .recording)
      #expect(await rig.service.queuedItems().map(\.id) == [id.wireID], "the outbox item carries the same id")
      _ = try await rig.controller.stop()
    }

    @Test("the follower attaches after the session started: the activity is still driven")
    func followerAttachesAfterTheSession() async throws {
      let rig = StartRig()
      let id = try await rig.controller.start(mode: .hermes, activityFirst: true)
      await rig.capture.recordWithoutClock(seconds: 3)
      _ = try await rig.controller.stop()

      for _ in 0..<1_000 where rig.activity.base.phases(of: id.wireID).last != .uploading {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(rig.activity.base.phases(of: id.wireID).contains(.uploading))
    }

    @Test("a foreground start keeps today's order: the session first, the activity after")
    func foregroundOrderUnchanged() async throws {
      let rig = StartRig()

      let id = try await rig.controller.start(mode: .hermes, source: "app")

      #expect(await rig.order.events == ["session.activate", "activity.start"])
      #expect(rig.activity.base.starts.map(\.memoID) == [id.wireID])
      _ = try await rig.controller.stop()
    }

    @Test("a refused Live Activity aborts before the session activates and asks for the foreground")
    func refusedActivity() async throws {
      let rig = StartRig()
      rig.activity.base.refuseStarts(reason: "visibility: Target is not foreground")

      await #expect(throws: StartMemoError.backgroundStartRefused) {
        try await rig.controller.start(mode: .hermes, activityFirst: true)
      }

      #expect(await rig.order.events == ["activity.start"], "the session was never activated")
      #expect(rig.activity.base.refusedIDs.count == 1 && rig.activity.base.ends.isEmpty)
      #expect(await rig.capture.session.activationCount == 0)
      try await rig.expectNothingLeft()
    }

    @Test("a refused Live Activity in the foreground order does not stop the take")
    func refusedActivityInTheForeground() async throws {
      let rig = StartRig()
      rig.activity.base.refuseStarts(reason: "denied")

      _ = try await rig.controller.start(mode: .hermes)

      #expect(try await rig.stack.session().current.phase == .recording)
      _ = try await rig.controller.stop()
    }

    @Test("a session that will not activate ends the activity at once and leaves no outbox item")
    func activationRefused() async throws {
      let rig = StartRig()
      await rig.capture.session.failActivations(1)

      await #expect(throws: StartMemoError.backgroundStartRefused) {
        try await rig.controller.start(mode: .hermes, activityFirst: true)
      }

      #expect(await rig.order.events == ["activity.start", "session.activate", "activity.end"])
      #expect(rig.activity.base.ends.map(\.dismissal) == [.immediate])
      #expect(rig.activity.base.endedIDs == rig.activity.base.starts.map(\.memoID))
      try await rig.expectNothingLeft()
    }

    @Test("an engine that will not start is the same refusal, and the queued item is discarded")
    func engineRefused() async throws {
      let rig = StartRig(refusingRecorder: true)

      await #expect(throws: StartMemoError.backgroundStartRefused) {
        try await rig.controller.start(mode: .hermes, activityFirst: true)
      }

      #expect(rig.activity.base.ends.map(\.dismissal) == [.immediate])
      try await rig.expectNothingLeft()
    }

    @Test("a microphone refusal is not a background refusal: it throws unchanged and leaves nothing")
    func microphoneDenied() async throws {
      let rig = StartRig(permission: false)

      await #expect(throws: StartMemoError.microphoneDenied) {
        try await rig.controller.start(mode: .hermes, activityFirst: true)
      }

      #expect(await rig.order.events.isEmpty, "neither the activity nor the session was touched")
      try await rig.expectNothingLeft()
    }

    @Test("only session and engine failures count as a refusal")
    func classification() {
      #expect(BackgroundStartRefusal.isRefusal(CaptureError.sessionFailure("!int")))
      #expect(BackgroundStartRefusal.isRefusal(CaptureError.sessionRefused("!int")))
      #expect(BackgroundStartRefusal.isRefusal(CaptureError.engineFailure("!rec")))
      #expect(!BackgroundStartRefusal.isRefusal(CaptureError.alreadyRecording))
      #expect(!BackgroundStartRefusal.isRefusal(StartMemoError.microphoneDenied))
    }

    @Test("the session minted id is used when none is given, and the given one when it is")
    func sessionAcceptsAMintedID() async throws {
      let rig = StartRig()
      let session = try await rig.stack.session()
      let minted = MemoID()

      let id = try await session.start(TakeRequest(mode: "auto", title: "Voice memo"), memoID: minted)

      #expect(id == minted)
      _ = try await session.stop()
    }
  }

  @MainActor
  @Suite("The foreground fallback of the Shortcuts start")
  struct ForegroundFallbackTests {
    private func root() throws -> (CompositionRoot, RecordingLiveActivity) {
      let root = CompositionRoot(arguments: ["-IrisFakeCapture"], credentials: InMemoryCredentialStore())
      root.isAppActive = { false }
      return (root, try #require(root.fakeLiveActivity))
    }

    @Test("a refused background start continues in the foreground, starts the take there and logs the road")
    func refusedThenForeground() async throws {
      let (root, activity) = try root()
      let capture = try #require(root.fakeCapture)
      await capture.session.failActivations(1)
      var roads: [StartRoad] = []
      var continued = 0

      try await StartMemoFallback.run(
        canContinueInForeground: { true },
        background: { try await root.startMemoFromShortcut() },
        continueInForeground: { continued += 1 },
        foreground: { try await root.startMemo() },
        road: { roads.append($0) })

      #expect(roads == [.foregroundFallback] && continued == 1)
      #expect(activity.starts.count == 2, "the refused attempt's card, then the foreground take's")
      #expect(activity.ends.map(\.dismissal) == [.immediate], "the refused attempt's card went at once")
      #expect(activity.endedIDs == [activity.starts[0].memoID])
      #expect(await root.outbox.queuedItems().count == 1, "the foreground take is recording in the outbox")
      #expect(root.take.failure == nil)
      #expect(StartRoad.foregroundFallback.rawValue == "foreground_fallback")
      _ = try await root.stopMemo()
    }

    @Test("a background start that works never asks for the foreground")
    func backgroundWorks() async throws {
      let (root, activity) = try root()
      var roads: [StartRoad] = []

      try await StartMemoFallback.run(
        canContinueInForeground: { true },
        background: { try await root.startMemoFromShortcut() },
        continueInForeground: { Issue.record("asked for the foreground") },
        foreground: { Issue.record("started twice") },
        road: { roads.append($0) })

      #expect(roads == [.background])
      #expect(activity.starts.count == 1)
      _ = try await root.stopMemo()
    }

    @Test("when the system cannot continue in the foreground the localized error is thrown and nothing is left")
    func cannotContinue() async throws {
      let (root, activity) = try root()
      let capture = try #require(root.fakeCapture)
      await capture.session.failActivations(1)
      var roads: [StartRoad] = []

      await #expect(throws: StartMemoError.backgroundStartRefused) {
        try await StartMemoFallback.run(
          canContinueInForeground: { false },
          background: { try await root.startMemoFromShortcut() },
          continueInForeground: { Issue.record("cannot continue") },
          foreground: { Issue.record("started in the foreground") },
          road: { roads.append($0) })
      }

      #expect(roads.isEmpty)
      #expect(activity.liveIDs.isEmpty)
      #expect(await root.outbox.queuedItems().isEmpty)
      #expect(!String(localized: StartMemoError.backgroundStartRefused.localizedStringResource).isEmpty)
    }

    @Test("a failure that is not a refusal is thrown unchanged and never reaches the foreground")
    func notARefusal() async throws {
      let root = CompositionRoot(arguments: [], credentials: InMemoryCredentialStore())
      root.isAppActive = { false }

      await #expect(throws: StartMemoError.notConfigured) {
        try await StartMemoFallback.run(
          canContinueInForeground: { true },
          background: { try await root.startMemoFromShortcut() },
          continueInForeground: { Issue.record("not a refusal") },
          foreground: { Issue.record("not a refusal") },
          road: { _ in Issue.record("no road ran") })
      }
    }

    @Test("a Shortcut that fails in the foreground order sees a localized recorder error")
    func foregroundFailureIsLocalized() async throws {
      let (root, _) = try root()
      root.isAppActive = { true }
      let capture = try #require(root.fakeCapture)
      await capture.session.failActivations(1)

      await #expect(throws: StartMemoError.recordingFailed) { try await root.startMemoFromShortcut() }
      #expect(await root.outbox.queuedItems().isEmpty)
    }

    @Test("the foreground-continued Shortcut start sees a localized recorder error too")
    func continuedForegroundFailureIsLocalized() async throws {
      let (root, _) = try root()
      let capture = try #require(root.fakeCapture)
      await capture.session.failActivations(1)

      await #expect(throws: StartMemoError.recordingFailed) { try await root.startMemoFromShortcutInForeground() }
      #expect(await root.outbox.queuedItems().isEmpty)
    }

    @Test("the Control's start keeps the foreground order whatever the app state says")
    func controlIgnoresAppState() async throws {
      let (root, activity) = try root()

      _ = try await OpenRecorderIntent().perform()

      #expect(activity.starts.count == 1)
      _ = try await root.stopMemo()
    }
  }
}
