import Foundation
import IrisCapture
import IrisCore
import Testing
import os

@testable import Iris

/// A take cancelled after the server created its memo: the outbox deletes the memo, History never shows it, and a late
/// segment or `complete` (a 409 `bad_state` once the memo is deleted) is dropped, never a stall.
@MainActor
@Suite("Cancelled take")
struct CancelledTakeTests {
  let client = FakeAPIClient(now: { MemoFactory.now })

  private func waitFor(seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
    for _ in 0..<Int(seconds * 100) {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
  }

  /// A take with more than ten seconds of audio, so its first segment has closed and the memo exists on the server.
  private func createdTake(_ rig: OutboxRig) async throws -> (CaptureSession, MemoID) {
    let session = try await rig.stack.session()
    let id = try await session.start(TakeRequest(mode: "auto", title: "Voice memo"))
    await rig.capture.recordWithoutClock(seconds: 12)
    #expect(
      await waitFor { await rig.created.memo(id: id.wireID) != nil }, "the memo was created with its first segment")
    return (session, id)
  }

  private func deleted(_ id: MemoID) async -> Bool {
    (try? await client.memo(id: id.wireID))?.memo.isDeleted == true
  }

  @Test("cancelling deletes the memo the server already has")
  func cancelDeletesTheServerMemo() async throws {
    let rig = OutboxRig(client: client)
    let (session, id) = try await createdTake(rig)

    await session.cancel()

    #expect(await waitFor { await deleted(id) })
    #expect(await client.calls.contains(.deleteMemo(id: id.wireID)))
    #expect(await rig.service.queuedItems().isEmpty)
    let outbox = try await rig.stack.outbox()
    #expect(await waitFor { await outbox.entries().isEmpty })
  }

  @Test("after the delete a late segment or complete is a 409 bad_state")
  func lateTransfersAreRefused() async throws {
    let rig = OutboxRig(client: client)
    let (session, id) = try await createdTake(rig)
    await session.cancel()
    #expect(await waitFor { await deleted(id) })

    for call in [
      { try await client.uploadSegment(memoID: id.wireID, index: 9, data: Data([1])) },
      { _ = try await client.completeMemo(id: id.wireID, request: CompleteMemoRequest(segmentCount: 1)) },
    ] as [() async throws -> Void] {
      do {
        try await call()
        Issue.record("the server accepted a transfer for a deleted memo")
      } catch APIError.server(let status, let body) {
        #expect(status == 409 && body.error == .badState)
      }
    }
  }

  @Test("a take cancelled before its first segment never reaches the server, so there is nothing to delete")
  func cancelBeforeTheMemoExists() async throws {
    let rig = OutboxRig(client: client)
    let session = try await rig.stack.session()
    _ = try await session.start(TakeRequest(mode: "auto", title: "Voice memo"))
    await session.cancel()
    let outbox = try await rig.stack.outbox()
    await outbox.settled()

    #expect(await !client.calls.contains { if case .deleteMemo = $0 { true } else { false } })
    #expect(await !client.calls.contains { if case .createMemo = $0 { true } else { false } })
  }

  @Test("a delete that fails offline is kept and retried, and the take stays out of the queue meanwhile")
  func deleteIsRetried() async throws {
    let store = InMemoryOutboxStore()
    let rig = OutboxRig(client: client, store: store)
    let (session, id) = try await createdTake(rig)
    await client.enqueueFailure(.transport(.notConnectedToInternet), for: .deleteMemo)

    await session.cancel()
    #expect(await waitFor { await client.calls.contains(.deleteMemo(id: id.wireID)) })
    #expect(await rig.service.queuedItems().isEmpty, "a deletion is bookkeeping, not a queue row")
    #expect(await !deleted(id))
    // The retry timer is armed once the outbox has recorded the failure (a persisted deadline).
    #expect(
      await waitFor {
        if case .failed? = try? await store.load().deletions.first?.state { true } else { false }
      })

    await rig.clock.advance(by: 2)
    #expect(await waitFor { await deleted(id) })
  }

  @Test("a segment that was on the wire when the take was cancelled is dropped on its 409, not stalled")
  func inFlightSegmentIsDroppedOnConflict() async throws {
    let gate = UploadGate()
    let created = CreatedMemoLog()
    let capture = FakeCapture(
      directory: FileManager.default.temporaryDirectory.appending(path: "iris-unit-\(UUID().uuidString)"))
    let stack = CaptureStack(
      .init(
        session: capture.session, routes: capture.routes, recorder: capture.recorder, clock: ManualClock(),
        store: InMemoryOutboxStore(),
        uploader: GatedUploader(base: APIOutboxUploader(client: client, created: created), gate: gate)))
    let session = try await stack.session()
    let outbox = try await stack.outbox()
    let id = try await session.start(TakeRequest(mode: "auto", title: "Voice memo"))
    await capture.recordWithoutClock(seconds: 12)
    #expect(await waitFor { await gate.arrived > 0 }, "the first segment is on the wire")
    let file = try #require(await outbox.entries().first?.segment.fileURL)

    await session.cancel()
    #expect(await waitFor { await deleted(id) })
    await gate.open()

    // The upload now answers 409 bad_state for the deleted memo: nothing is queued, nothing stalled, the file is gone.
    #expect(await waitFor { await outbox.entries().isEmpty })
    #expect(await outbox.queue().isEmpty)
    #expect(await !FileManager.default.fileExists(atPath: file.path))
  }

  @Test("a Discard that loses to a stop in flight hides nothing, deletes nothing and the memo is sent")
  func discardLosesToStop() async throws {
    let gate = UploadGate()
    let created = CreatedMemoLog()
    let forgotten = OSAllocatedUnfairLock<[String]>(initialState: [])
    await created.setForgottenHandler { id in forgotten.withLock { $0.append(id) } }
    let capture = FakeCapture(
      directory: FileManager.default.temporaryDirectory.appending(path: "iris-unit-\(UUID().uuidString)"))
    let stack = CaptureStack(
      .init(
        session: capture.session, routes: capture.routes,
        recorder: StopGatedRecorder(base: capture.recorder, gate: gate), clock: ManualClock(),
        store: InMemoryOutboxStore(), uploader: APIOutboxUploader(client: client, created: created),
        policy: OutboxPolicy(jitter: { 0 })))
    let service = OutboxService(stack: stack, created: created)
    let controller = TakeController(
      stack: stack,
      liveActivity: TakeLiveActivityCoordinator(activity: RecordingLiveActivity(), stack: stack, created: created),
      outbox: service, microphone: nil, canRecord: true, isConfigured: { true }, requestPermission: { true })

    let id = try await controller.start(mode: .auto)
    await capture.recordWithoutClock(seconds: 12)
    #expect(await waitFor { await created.memo(id: id.wireID) != nil })

    // The Stop is flushing its last segment when Discard is tapped: Discard waits for it and finds the take over.
    let stopping = Task { try await controller.stop() }
    #expect(await waitFor { await gate.arrived > 0 }, "the stop is suspended inside the recorder")
    let discarding = Task { await controller.cancel() }
    try await Task.sleep(for: .milliseconds(100))
    await gate.open()
    let result = try await stopping.value
    await discarding.value

    #expect(result != nil, "the stop won: the take was sent")
    #expect(forgotten.withLock { $0 }.isEmpty, "a take that was sent is not hidden from History")
    #expect(await !client.calls.contains(.deleteMemo(id: id.wireID)))
    #expect(await waitFor { (try? await client.memo(id: id.wireID))?.memo.state == .received })
    #expect(await client.calls.contains { if case .completeMemo = $0 { true } else { false } })
  }

  @Test("the Live Activity of a cancelled take ends at once; it is not handed to the server")
  func activityEndsOnCancel() async throws {
    let rig = OutboxRig(client: client)
    let activity = RecordingLiveActivity()
    let coordinator = TakeLiveActivityCoordinator(activity: activity, stack: rig.stack, created: rig.created)
    let session = try await rig.stack.session()
    let id = try await session.start(TakeRequest(mode: "auto", title: "Voice memo"))
    await coordinator.begin(memoID: id, mode: .auto, startedAt: MemoFactory.now)
    await rig.capture.recordWithoutClock(seconds: 12)
    #expect(await waitFor { await rig.created.memo(id: id.wireID) != nil })

    await session.cancel()
    await coordinator.finished()

    #expect(await activity.ends == [.init(finalState: nil, dismissal: .immediate)])
    #expect(await !activity.handedOver)
    #expect(await !activity.phases.contains(.processing))
  }

  @Test("a take that starts while an earlier memo is still sending says so in its activity")
  func queueNote() async throws {
    let rig = OutboxRig(client: client)
    await client.enqueueFailure(.transport(.notConnectedToInternet), for: .createMemo)
    let activity = RecordingLiveActivity()
    let coordinator = TakeLiveActivityCoordinator(activity: activity, stack: rig.stack, created: rig.created)
    let session = try await rig.stack.session()

    let first = try await session.start(TakeRequest(mode: "auto", title: "Voice memo"))
    await coordinator.begin(memoID: first, mode: .auto, startedAt: MemoFactory.now)
    await rig.capture.recordWithoutClock(seconds: 3)
    _ = try await session.stop()
    #expect(await waitFor { await rig.service.queuedItems().count == 1 })

    let second = try await session.start(TakeRequest(mode: "auto", title: "Voice memo"))
    await coordinator.begin(memoID: second, mode: .auto, startedAt: MemoFactory.now)

    let state = try #require(await activity.states.last)
    #expect(state.phase == .recording)
    #expect(state.headline == "1 earlier memo is still sending")
    #expect((state.headline?.count ?? 0) <= 60)
    await session.cancel()
    await coordinator.stop()
  }
}

/// Holds every upload until `open()`, so a test can cancel a take while a segment is on the wire.
private actor UploadGate {
  private(set) var arrived = 0
  private var isOpen = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  func pass() async {
    arrived += 1
    guard !isOpen else { return }
    await withCheckedContinuation { waiting.append($0) }
  }

  func open() {
    isOpen = true
    for continuation in waiting { continuation.resume() }
    waiting = []
  }
}

private nonisolated struct GatedUploader: SegmentUploader {
  let base: APIOutboxUploader
  let gate: UploadGate

  func create(_ item: OutboxItem) async throws { try await base.create(item) }

  func upload(_ segment: ClosedSegment) async throws {
    await gate.pass()
    try await base.upload(segment)
  }

  func complete(memoID: MemoID, segmentCount: Int) async throws {
    try await base.complete(memoID: memoID, segmentCount: segmentCount)
  }

  func delete(memoID: MemoID) async throws { try await base.delete(memoID: memoID) }
}

/// A recorder whose `stop()` waits for the gate, so a test can hold a Stop inside its last flush.
private nonisolated struct StopGatedRecorder: SegmentRecorder {
  let base: FakeSegmentRecorder
  let gate: UploadGate

  var events: AsyncStream<CaptureEvent> { base.events }
  var levels: AsyncStream<Float> { base.levels }

  func start(memoID: MemoID) async throws { try await base.start(memoID: memoID) }

  func stop() async throws {
    await gate.pass()
    try await base.stop()
  }

  func rotate(for reason: RotationReason) async { await base.rotate(for: reason) }
  func pause() async { await base.pause() }
  func resume() async { await base.resume() }
}
