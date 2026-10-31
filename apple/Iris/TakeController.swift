import Foundation
import IrisCapture
import IrisCore

/// The one door to a take in the app: the take screen, the banner, the start intent and the Live Activity buttons all go
/// through it. A take starts the capture session, feeds the silent microphone under `-IrisFakeCapture`, and requests the
/// take's Live Activity (Apple stops a background recording that has none), so leaving the app moves the take there.
///
/// Recording takes priority over playback, through one synchronous flag, ``captureActive``: a start sets it before it awaits
/// anything, and it is cleared only once the session has ended (the recorder's stop has returned). The player reads it
/// right before it starts anything. A thread's hold-to-talk takes the same claim (``claimCapture()``) through
/// ``OutboxVoiceReplyCapture``.
@MainActor
final class TakeController {
  private let stack: CaptureStack
  private let liveActivity: TakeLiveActivityCoordinator
  private let outbox: OutboxService
  private let microphone: FakeMicrophone?
  private let isConfigured: () -> Bool
  private let requestPermission: @Sendable () async -> Bool
  private let speech: SpeechPlayer?
  /// The live preview's tap and recognizer; `nil` leaves the take screen without one.
  let preview: LivePreviewSource?
  /// A take holds the microphone or is about to: set synchronously by ``claimCapture()``, cleared by ``releaseCapture(_:)``
  /// when the session has ended. No timeout.
  private(set) var captureActive = false
  /// The latest claim, so a release that belongs to an earlier take cannot clear a newer one.
  private var captureClaim = 0
  /// `false` when the engine recorder could not be built: nothing can record.
  let canRecord: Bool
  /// The start in flight: a second start while it runs joins it instead of racing it (the Control and the record button
  /// pressed together, a double tap), so the two calls yield one take.
  private var starting: Task<MemoID, any Error>?

  init(
    stack: CaptureStack, liveActivity: TakeLiveActivityCoordinator, outbox: OutboxService, microphone: FakeMicrophone?,
    canRecord: Bool, isConfigured: @escaping () -> Bool, requestPermission: @escaping @Sendable () async -> Bool,
    speech: SpeechPlayer? = nil, preview: LivePreviewSource? = nil
  ) {
    self.stack = stack
    self.liveActivity = liveActivity
    self.outbox = outbox
    self.microphone = microphone
    self.canRecord = canRecord
    self.isConfigured = isConfigured
    self.requestPermission = requestPermission
    self.speech = speech
    self.preview = preview
  }

  /// Whether a take can be started right now (a server is saved and a recorder exists).
  var canStart: Bool { canRecord && isConfigured() }

  /// Starts a take in `mode` with its Live Activity. Starts that overlap are one take: the later call returns the memo the
  /// first one started, and so does a start that finds a take already running.
  @discardableResult
  func start(mode: MemoMode, source: String = "app") async throws -> MemoID {
    DeviceLog.shared.commandSource = source
    if let starting { return try await starting.value }
    let claim = claimCapture()
    let task = Task { try await beginOrJoinRunning(mode: mode) }
    starting = task
    defer { starting = nil }
    do {
      return try await task.value
    } catch {
      await releaseCapture(claim)
      throw error
    }
  }

  /// A take is about to open the microphone: playback stops now and nothing starts until ``releaseCapture(_:)``. Called
  /// before the first `await` of a start, a thread's included. The token goes back to `releaseCapture`.
  @discardableResult
  func claimCapture() -> Int {
    captureClaim += 1
    captureActive = true
    speech?.pauseForTake()
    return captureClaim
  }

  /// The take of `claim` is over, or never began: clears the flag unless a later claim exists or the session still holds a
  /// take (a start that failed because another take was running does not end that one).
  func releaseCapture(_ claim: Int) async {
    guard claim == captureClaim else { return }
    let holding = await sessionHoldsMicrophone()
    guard claim == captureClaim, !holding else { return }
    captureActive = false
  }

  private func sessionHoldsMicrophone() async -> Bool {
    guard let session = try? await stack.session() else { return false }
    switch await session.current.phase {
    case .starting, .recording, .paused, .stopping: return true
    case .idle, .failed: return false
    }
  }

  /// The shared start: callers that joined it get the same answer, the recovery included.
  private func beginOrJoinRunning(mode: MemoMode) async throws -> MemoID {
    do {
      return try await begin(mode: mode)
    } catch CaptureError.alreadyRecording {
      // A take that was already running (started by something that is not in flight any more): that is the take.
      guard let session = try? await stack.session(), let running = await runningMemoID(of: session) else {
        throw CaptureError.alreadyRecording
      }
      return running
    }
  }

  private func runningMemoID(of session: CaptureSession) async -> MemoID? {
    let state = await session.current
    // A reply bound to a thread (its own hold-to-talk) is not the take a start was asking for.
    guard state.request?.threadID == nil else { return nil }
    switch state.phase {
    case .starting, .recording, .paused: return state.memoID
    case .idle, .stopping, .failed: return nil
    }
  }

  private func begin(mode: MemoMode) async throws -> MemoID {
    guard isConfigured() else { throw StartMemoError.notConfigured }
    guard canRecord else { throw StartMemoError.queueUnavailable }
    guard await requestPermission() else { throw StartMemoError.microphoneDenied }
    guard let session = try? await stack.session() else { throw StartMemoError.queueUnavailable }
    let request = TakeRequest(
      mode: mode.rawValue, title: String(localized: "Voice memo", comment: "Outbox row of a recorded memo"))
    let id = try await session.start(request)
    microphone?.start()
    let startedAt = await session.current.startedAt ?? Date()
    await liveActivity.begin(memoID: id, mode: mode, startedAt: startedAt)
    return id
  }

  /// Ends the take: the memo is finished in the outbox. `nil` when there is none, or nothing was said.
  @discardableResult
  func stop(source: String = "app") async throws -> TakeResult? {
    DeviceLog.shared.commandSource = source
    let claim = captureClaim
    await microphone?.stop()
    do {
      let result = try await stack.session().stop()
      await releaseCapture(claim)
      return result
    } catch {
      await releaseCapture(claim)
      throw error
    }
  }

  /// Drops the take. History stops showing its memo at once (the server may already have it), and the outbox deletes it there.
  /// Only the memo the session actually discarded is hidden: a Stop already in flight wins the session's gate, the take is
  /// then sent, and the Discard that arrived late changes nothing. Throws `queueUnavailable` when the capture session cannot
  /// be opened (the outbox file is unreadable): nothing was discarded, and the caller says so instead of looking done.
  func cancel() async throws {
    let claim = captureClaim
    await microphone?.stop()
    guard let session = try? await stack.session() else { throw StartMemoError.queueUnavailable }
    let id = await session.cancel()
    await releaseCapture(claim)
    if let id { await outbox.created.forget(id.wireID) }
  }

  /// Pauses a recording take, resumes a paused one.
  func togglePause(source: String = "app") async {
    DeviceLog.shared.commandSource = source
    guard let session = try? await stack.session() else { return }
    if await session.current.phase == .paused {
      await session.resume()
    } else {
      await session.pause()
    }
  }

  func switchInput(to uid: String, source: String = "app") async throws {
    DeviceLog.shared.commandSource = source
    try await stack.session().switchInput(to: uid)
  }

  /// The next available microphone after the one in use (the Live Activity's mic-swap button).
  func switchToNextInput(source: String = "app") async throws {
    let route = await stack.routes.currentRoute()
    let inputs = route.availableInputs
    guard inputs.count > 1 else { return }
    let current = inputs.firstIndex { $0.uid == route.currentInput?.uid } ?? -1
    try await switchInput(to: inputs[(current + 1) % inputs.count].uid, source: source)
  }

  func route() async -> RouteSnapshot { await stack.routes.currentRoute() }

  func updates() async -> AsyncStream<TakeState>? {
    guard let session = try? await stack.session() else { return nil }
    return await session.updates()
  }

  func levels() async -> AsyncStream<Float>? {
    guard let session = try? await stack.session() else { return nil }
    return session.levels
  }

  func queueChanges() async -> AsyncStream<Void> { await outbox.changes() }

  func queuedItems() async -> [QueuedItem] { await outbox.queuedItems() }
}
