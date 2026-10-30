import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import Iris

private func waitFor(seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
  for _ in 0..<Int(seconds * 100) {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return await condition()
}

/// Wave 16 I1: a connection change does not end a live take's activity, two starts are one take, a cancel that cannot reach
/// the session says so, and push tokens are registered in the order they arrive.
@MainActor
@Suite("Capture follow-ups")
struct CaptureFollowUpTests {
  let client = FakeAPIClient(now: { MemoFactory.now })

  private func controller(
    _ rig: OutboxRig, activity: RecordingLiveActivity = RecordingLiveActivity()
  ) -> (TakeController, TakeLiveActivityCoordinator) {
    let coordinator = TakeLiveActivityCoordinator(activity: activity, stack: rig.stack, created: rig.created)
    let controller = TakeController(
      stack: rig.stack, liveActivity: coordinator, outbox: rig.service, microphone: nil, canRecord: true,
      isConfigured: { true }, requestPermission: { true })
    return (controller, coordinator)
  }

  @Test("endOrphans spares the take this process is recording, and sweeps once it is over")
  func orphansSpareTheLiveTake() async throws {
    let rig = OutboxRig(client: client)
    let activity = RecordingLiveActivity()
    let (controller, coordinator) = controller(rig, activity: activity)
    let id = try await controller.start(mode: .auto)

    await coordinator.endOrphans()  // the connection changed mid-take

    #expect(await activity.sparedBySweeps == [[id.wireID]], "the live take keeps its activity")
    #expect(await !activity.ended)

    try await controller.stop()
    await coordinator.finished()
    await coordinator.endOrphans()
    #expect(await activity.sparedBySweeps.last == [], "nothing is live any more")
  }

  @Test("two starts at once are one take with one Live Activity")
  func doubleStart() async throws {
    let rig = OutboxRig(client: client)
    let activity = RecordingLiveActivity()
    let (controller, _) = controller(rig, activity: activity)

    async let first = controller.start(mode: .auto)
    async let second = controller.start(mode: .auto)
    let (a, b) = try await (first, second)

    #expect(a == b, "both callers got the one take")
    let session = try await rig.stack.session()
    #expect(await session.current.memoID == a)
    #expect(await activity.starts.count == 1)
    // A start that finds the take already running is that take too, not an error.
    #expect(try await controller.start(mode: .auto) == a)
    try await controller.stop()
  }

  @Test("two overlapping starts while a take already runs both get that take")
  func overlappingStartsWhileRunning() async throws {
    let rig = OutboxRig(client: client)
    let activity = RecordingLiveActivity()
    let (controller, _) = controller(rig, activity: activity)
    let running = try await controller.start(mode: .auto)

    async let first = controller.start(mode: .auto)
    async let second = controller.start(mode: .auto)
    let (a, b) = try await (first, second)

    #expect(a == running && b == running, "the joined caller recovers the running take too, not alreadyRecording")
    #expect(await activity.starts.count == 1)
    try await controller.stop()
  }

  @Test("a start after a failed one is a new attempt")
  func startAfterFailure() async throws {
    let rig = OutboxRig(client: client)
    let activity = RecordingLiveActivity()
    let coordinator = TakeLiveActivityCoordinator(activity: activity, stack: rig.stack, created: rig.created)
    let denied = TakeController(
      stack: rig.stack, liveActivity: coordinator, outbox: rig.service, microphone: nil, canRecord: true,
      isConfigured: { true }, requestPermission: { false })
    await #expect(throws: StartMemoError.microphoneDenied) { try await denied.start(mode: .auto) }
    await #expect(throws: StartMemoError.microphoneDenied) { try await denied.start(mode: .auto) }
  }

  @Test("cancel reports it when the capture session cannot be opened, and Discard says so")
  func cancelReportsASessionFailure() async throws {
    let capture = FakeCapture(
      directory: FileManager.default.temporaryDirectory.appending(path: "iris-cancel-\(UUID().uuidString)"))
    let created = CreatedMemoLog()
    let stack = CaptureStack(
      .init(
        session: capture.session, routes: capture.routes, recorder: capture.recorder, clock: ManualClock(),
        store: UnreadableOutboxStore(), uploader: APIOutboxUploader(client: client, created: created)))
    let service = OutboxService(stack: stack, created: created)
    let controller = TakeController(
      stack: stack,
      liveActivity: TakeLiveActivityCoordinator(activity: RecordingLiveActivity(), stack: stack, created: created),
      outbox: service, microphone: nil, canRecord: true, isConfigured: { true }, requestPermission: { true })

    await #expect(throws: StartMemoError.queueUnavailable) { try await controller.cancel() }

    let model = TakeModel(controller: controller)
    var take = TakeState.idle
    take.phase = .recording
    take.memoID = MemoID()
    model.apply(take)
    await model.discard()
    #expect(model.failure != nil, "the discard did not go through, and the user is told")
  }

  @Test("a token that rotates while a PUT is out is sent after it, never beside it")
  func tokensGoOutOneAtATime() async throws {
    let id = MemoID().wireID
    await client.seed(MemoFactory.detail(MemoFactory.memo(id)))
    let registrar = ActivityTokenRegistrar(client: client, sleep: { _ in await Task.yield() })
    registrar.begin(id)
    await registrar.memoCreated(id)
    let gate = await client.hold(.setActivityToken)

    let first = Task { await registrar.setToken(id, "aa") }
    #expect(await waitUntilHeld(gate), "the first PUT is out and its answer is slow")
    await registrar.setToken(id, "bb")  // rotates meanwhile
    let tokens = await client.calls.compactMap { call -> String? in
      if case .setActivityToken(id, let request) = call { request.token } else { nil }
    }
    #expect(tokens == ["aa"], "no second PUT beside the first")

    gate.release()
    await first.value

    #expect(await client.activityTokens[id] == "bb", "the newest token is the one the server ends with")
    let sent = await client.calls.compactMap { call -> String? in
      if case .setActivityToken(id, let request) = call { request.token } else { nil }
    }
    #expect(sent == ["aa", "bb"], "in the order the tokens arrived")
  }

  @Test("an activity that ends while a PUT is out stops the loop")
  func finishDuringSend() async throws {
    let id = MemoID().wireID
    await client.seed(MemoFactory.detail(MemoFactory.memo(id)))
    let registrar = ActivityTokenRegistrar(client: client, sleep: { _ in await Task.yield() })
    registrar.begin(id)
    await registrar.memoCreated(id)
    let gate = await client.hold(.setActivityToken)
    let sending = Task { await registrar.setToken(id, "aa") }
    #expect(await waitUntilHeld(gate))

    registrar.finish(id)
    gate.release()
    await sending.value

    #expect(!registrar.isTracking(id))
  }

  @Test("a PUT that outlives finish and begin of the same memo does not clear the new entry's send flag")
  func beginAgainDuringSend() async throws {
    let id = MemoID().wireID
    await client.seed(MemoFactory.detail(MemoFactory.memo(id)))
    let registrar = ActivityTokenRegistrar(client: client, sleep: { _ in await Task.yield() })
    registrar.begin(id)
    await registrar.memoCreated(id)
    let first = await client.hold(.setActivityToken)
    let second = await client.hold(.setActivityToken)
    let old = Task { await registrar.setToken(id, "aa") }
    #expect(await waitUntilHeld(first), "the old activity's PUT is out and slow")

    registrar.finish(id)
    registrar.begin(id)  // the same memo again, a new activity
    await registrar.memoCreated(id)
    let newer = Task { await registrar.setToken(id, "bb") }
    #expect(await waitUntilHeld(second), "the new activity's PUT is out")

    first.release()
    await old.value
    await registrar.setToken(id, "cc")  // rotates while the new entry's PUT is still out
    func sent() async -> [String] {
      await client.calls.compactMap { call -> String? in
        if case .setActivityToken(id, let request) = call { request.token } else { nil }
      }
    }
    #expect(await sent() == ["aa", "bb"], "no PUT beside the new entry's: the old one did not clear its flag")

    second.release()
    await newer.value
    #expect(await sent() == ["aa", "bb", "cc"])
    #expect(await client.activityTokens[id] == "cc")
  }
}
