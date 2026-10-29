import Foundation
import IrisCapture
import IrisCore

/// The one door to a take in the app: the take screen, the banner, the start intent and the Live Activity buttons all go
/// through it. A take starts the capture session, feeds the silent microphone under `-IrisFakeCapture`, and requests the
/// take's Live Activity (Apple stops a background recording that has none), so leaving the app moves the take there.
@MainActor
final class TakeController {
  private let stack: CaptureStack
  private let liveActivity: TakeLiveActivityCoordinator
  private let outbox: OutboxService
  private let microphone: FakeMicrophone?
  private let isConfigured: () -> Bool
  private let requestPermission: @Sendable () async -> Bool
  /// `false` when the engine recorder could not be built: nothing can record.
  let canRecord: Bool

  init(
    stack: CaptureStack, liveActivity: TakeLiveActivityCoordinator, outbox: OutboxService, microphone: FakeMicrophone?,
    canRecord: Bool, isConfigured: @escaping () -> Bool, requestPermission: @escaping @Sendable () async -> Bool
  ) {
    self.stack = stack
    self.liveActivity = liveActivity
    self.outbox = outbox
    self.microphone = microphone
    self.canRecord = canRecord
    self.isConfigured = isConfigured
    self.requestPermission = requestPermission
  }

  /// Whether a take can be started right now (a server is saved and a recorder exists).
  var canStart: Bool { canRecord && isConfigured() }

  /// Starts a take in `mode` with its Live Activity.
  @discardableResult
  func start(mode: MemoMode) async throws -> MemoID {
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
  func stop() async throws -> TakeResult? {
    await microphone?.stop()
    return try await stack.session().stop()
  }

  /// Drops the take. History stops showing its memo at once (the server may already have it), and the outbox deletes it there.
  func cancel() async {
    await microphone?.stop()
    guard let session = try? await stack.session() else { return }
    if let id = await session.current.memoID { await outbox.created.forget(id.wireID) }
    await session.cancel()
  }

  /// Pauses a recording take, resumes a paused one.
  func togglePause() async {
    guard let session = try? await stack.session() else { return }
    if await session.current.phase == .paused {
      await session.resume()
    } else {
      await session.pause()
    }
  }

  func switchInput(to uid: String) async throws {
    try await stack.session().switchInput(to: uid)
  }

  /// The next available microphone after the one in use (the Live Activity's mic-swap button).
  func switchToNextInput() async throws {
    let route = await stack.routes.currentRoute()
    let inputs = route.availableInputs
    guard inputs.count > 1 else { return }
    let current = inputs.firstIndex { $0.uid == route.currentInput?.uid } ?? -1
    try await switchInput(to: inputs[(current + 1) % inputs.count].uid)
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
