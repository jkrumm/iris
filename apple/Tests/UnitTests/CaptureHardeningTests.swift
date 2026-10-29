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

/// A store whose `load` always fails after a short pause, and which counts how many loads overlap: two builds of the
/// capture stack over one queue file would clobber each other's saves.
private actor OverlapCountingStore: OutboxStore {
  struct Unreadable: Error {}

  private var running = 0
  private(set) var maxRunning = 0
  private(set) var loads = 0

  func load() async throws -> OutboxRecord {
    loads += 1
    running += 1
    maxRunning = max(maxRunning, running)
    try? await Task.sleep(for: .milliseconds(2))
    running -= 1
    throw Unreadable()
  }

  func save(_ record: OutboxRecord) {}
}

@MainActor
@Suite("Capture stack single-flight")
struct CaptureStackTests {
  @Test("callers racing over a store that cannot be read never run two builds at once")
  func oneBuildAtATime() async {
    let store = OverlapCountingStore()
    let capture = FakeCapture(
      directory: FileManager.default.temporaryDirectory.appending(path: "iris-stack-\(UUID().uuidString)"))
    let stack = CaptureStack(
      .init(
        session: capture.session, routes: capture.routes, recorder: capture.recorder, clock: ManualClock(),
        store: store, uploader: APIOutboxUploader(client: FakeAPIClient(), created: CreatedMemoLog())))

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<24 {
        group.addTask {
          for _ in 0..<40 { _ = await stack.isAvailable() }
        }
      }
    }
    #expect(await store.loads > 1, "the failed build is retried by later callers")
    #expect(await store.maxRunning == 1, "but never while another build is still running")
  }
}

@MainActor
@Suite("Outbox uploader and stall budget")
struct UploaderHardeningTests {
  let client = FakeAPIClient(now: { MemoFactory.now })

  private func submission(_ n: UInt8 = 1) -> TextSubmission {
    TextSubmission(
      id: MemoID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n)), mode: .auto, text: "later",
      threadId: nil, startedAt: MemoFactory.now)
  }

  @Test("a segment file that exists but cannot be read is retried with the real error, not stalled as gone")
  func unreadableFileIsNotPermanent() async throws {
    // A directory where the file should be: it exists, and reading it fails.
    let url = FileManager.default.temporaryDirectory.appending(path: "iris-unreadable-\(UUID().uuidString).m4a")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let uploader = APIOutboxUploader(client: FakeAPIClient(), created: CreatedMemoLog())
    let segment = ClosedSegment(memoID: MemoID(), index: 0, fileURL: url, byteCount: 1, duration: 1)

    let thrown = await #expect(throws: (any Error).self) { try await uploader.upload(segment) }
    #expect(!(thrown is PermanentTransferError), "a read error is not a refusal: \(String(describing: thrown))")
  }

  @Test("twelve attempts without a network do not stall the item; it goes out when the network is back")
  func offlineNeverStalls() async throws {
    let rig = OutboxRig(client: client)
    for _ in 0..<12 { await client.enqueueFailure(.transport(.notConnectedToInternet), for: .createTextMemo) }
    #expect(await rig.service.submitText(submission()) == .queued)

    // Each backoff is at most five minutes: step past it until the item has gone through.
    var sent = false
    for _ in 0..<30 where !sent {
      await rig.clock.advance(by: 400)
      sent = await rig.drain(seconds: 0.3)
    }
    #expect(sent, "the item is still being retried after more than ten failures")
    #expect(await client.memos.count == 1)
  }

  @Test("server trouble (a 503) does not use up the attempts either")
  func serverTroubleNeverStalls() async throws {
    let rig = OutboxRig(client: client)
    let body = ErrorBody(error: .unavailable, message: "down")
    for _ in 0..<12 { await client.enqueueFailure(.server(status: 503, body: body), for: .createTextMemo) }
    #expect(await rig.service.submitText(submission()) == .queued)

    var sent = false
    for _ in 0..<30 where !sent {
      await rig.clock.advance(by: 400)
      sent = await rig.drain(seconds: 0.3)
    }
    #expect(sent)
  }

  @Test("resume skips the backoff: coming back online or to the foreground sends a waiting item now")
  func resumeSkipsTheBackoff() async throws {
    let rig = OutboxRig(client: client)
    await client.enqueueFailure(.transport(.notConnectedToInternet), for: .createTextMemo)
    #expect(await rig.service.submitText(submission()) == .queued)
    #expect(await client.memos.isEmpty)

    await rig.service.resume()  // the clock has not moved: the retry time is still ahead
    #expect(await rig.drain(seconds: 3))
    #expect(await client.memos.count == 1)
  }

  @Test("resume leaves a refused item stalled: that one waits for the user")
  func resumeLeavesRefusalsAlone() async throws {
    let rig = OutboxRig(client: client)
    // A recorded take for an unknown thread: the server answers 404, so the item stalls and stays queued.
    let voice = rig.voice()
    try await voice.begin(VoiceReplyRequest(threadId: "gone", mode: .hermes))
    #expect(try await voice.end(cancelled: false) == .queued)
    let calls = await client.calls.count

    await rig.service.resume()
    try await Task.sleep(for: .milliseconds(100))
    #expect(await client.calls.count == calls, "nothing was sent again")
    #expect(await rig.service.queuedItems().first?.state == .failed(retryAt: nil, reason: "thread gone not found"))
  }
}

@MainActor
@Suite("Live Activity follower")
struct LiveActivityFollowerTests {
  let client = FakeAPIClient(now: { MemoFactory.now })

  @Test("a follower that was stopped writes nothing more to the activity")
  func cancelledFollowerIsSilent() async throws {
    let rig = OutboxRig(client: client)
    let activity = RecordingLiveActivity()
    let coordinator = TakeLiveActivityCoordinator(activity: activity, stack: rig.stack, created: rig.created)
    let session = try await rig.stack.session()
    let id = try await session.start(TakeRequest(mode: "auto", title: "Voice memo"))
    await coordinator.begin(memoID: id, mode: .auto, startedAt: MemoFactory.now)

    await coordinator.stop()
    try await Task.sleep(for: .milliseconds(200))

    #expect(await activity.phases == [.recording], "no uploading write after the follower was cancelled")
    #expect(await !activity.ended && !activity.handedOver)
  }
}

@MainActor
@Suite("Live Activity of overlapping takes")
struct OverlappingTakeTests {
  let client = FakeAPIClient(now: { MemoFactory.now })

  @Test(
    "a take that starts while the last one is still uploading keeps its own activity, and the last one is handed over")
  func eachTakeKeepsItsOwnActivity() async throws {
    let rig = OutboxRig(client: client)
    let activity = RecordingLiveActivity()
    let coordinator = TakeLiveActivityCoordinator(activity: activity, stack: rig.stack, created: rig.created)
    let session = try await rig.stack.session()
    // The first memo cannot be created yet: it stays in the queue while the second take starts.
    await client.enqueueFailure(.transport(.notConnectedToInternet), for: .createMemo)

    let first = try await session.start(TakeRequest(mode: "auto", title: "Voice memo"))
    await coordinator.begin(memoID: first, mode: .auto, startedAt: MemoFactory.now)
    await rig.capture.recordWithoutClock(seconds: 3)
    _ = try await session.stop()
    #expect(await waitFor { await activity.phases(of: first.wireID).contains(.uploading) })
    // The first create has failed and is waiting out its backoff before the second take starts.
    #expect(
      await waitFor {
        await rig.service.queuedItems().contains {
          if case .failed(let at?, _) = $0.state { at > Date.distantPast } else { false }
        }
      })

    let second = try await session.start(TakeRequest(mode: "auto", title: "Voice memo"))
    await coordinator.begin(memoID: second, mode: .auto, startedAt: MemoFactory.now)
    #expect(await activity.phases(of: second.wireID).allSatisfy { $0 == .recording })

    // Back online: the first memo goes through while the second take is still recording.
    await rig.service.resume()
    #expect(await waitFor { await activity.handedOverIDs.contains(first.wireID) })
    #expect(
      await activity.phases(of: second.wireID).allSatisfy { $0 == .recording },
      "nothing of the first take reached the second")
    #expect(await !activity.handedOverIDs.contains(second.wireID) && !activity.endedIDs.contains(second.wireID))

    await rig.capture.recordWithoutClock(seconds: 3)
    _ = try await session.stop()
    #expect(await rig.drain())
    await coordinator.finished()
    #expect(await activity.handedOverIDs.sorted() == [first.wireID, second.wireID].sorted())
    #expect(await !activity.ended)
  }

  @Test("a recorder failure ends the take's activity as failed")
  func recorderFailureEndsTheActivity() async throws {
    let rig = OutboxRig(client: client)
    let activity = RecordingLiveActivity()
    let coordinator = TakeLiveActivityCoordinator(activity: activity, stack: rig.stack, created: rig.created)
    let session = try await rig.stack.session()
    let id = try await session.start(TakeRequest(mode: "auto", title: "Voice memo"))
    await coordinator.begin(memoID: id, mode: .auto, startedAt: MemoFactory.now)

    await rig.capture.recorder.fail(reason: "segment write failed")
    await coordinator.finished()

    #expect(await activity.ends.map(\.finalState?.phase) == [.failed])
    #expect(await activity.ends.first?.dismissal == .later)
    #expect(await activity.endedIDs == [id.wireID])
    await #expect(throws: CaptureError.recordingFailed("segment write failed")) { try await session.stop() }
  }
}

@MainActor
@Suite("Voice reply when the recorder fails")
struct VoiceRecorderFailureTests {
  let client = FakeAPIClient(now: { MemoFactory.now })

  @Test("a take that lost its audio ends as recordingFailed and queues nothing")
  func lostTake() async throws {
    let rig = OutboxRig(client: client)
    let voice = OutboxVoiceReplyCapture(
      stack: rig.stack, service: rig.service,
      willEnd: { [capture = rig.capture] in await capture.recorder.fail(reason: "segment write failed") })
    try await voice.begin(VoiceReplyRequest(threadId: "t", mode: .hermes))

    #expect(try await voice.end(cancelled: false) == .recordingFailed)
    #expect(await rig.service.queuedItems().isEmpty)
    #expect(await client.calls.isEmpty)
  }
}

@MainActor
@Suite("Activity push token registration")
struct ActivityTokenRegistrarTests {
  let client = FakeAPIClient(now: { MemoFactory.now })

  private func registrar() -> ActivityTokenRegistrar {
    // No real waiting between retries.
    ActivityTokenRegistrar(client: client, sleep: { _ in await Task.yield() })
  }

  private func tokens(of memoID: String) async -> [String] {
    await client.calls.compactMap {
      if case .setActivityToken(memoID, let request) = $0 { request.token } else { nil }
    }
  }

  @Test("a token that could not be sent at the hand-over is retried until the server has it")
  func retriesAfterTheHandOver() async throws {
    let id = MemoID().wireID
    await client.seed(MemoFactory.detail(MemoFactory.memo(id)))
    // Offline for the attempt when the memo is created and for the one at the hand-over.
    for _ in 0..<2 { await client.enqueueFailure(.transport(.notConnectedToInternet), for: .setActivityToken) }
    let registrar = registrar()
    registrar.begin(id)
    await registrar.setToken(id, "aa")
    await registrar.memoCreated(id)
    await registrar.handOver(id)
    #expect(await client.activityTokens[id] == nil)

    #expect(await waitFor { await client.activityTokens[id] == "aa" }, "the retry outlives the hand-over")
  }

  @Test("a token that rotates after the hand-over is registered too, until the activity ends")
  func rotationAfterTheHandOver() async throws {
    let id = MemoID().wireID
    await client.seed(MemoFactory.detail(MemoFactory.memo(id)))
    let registrar = registrar()
    registrar.begin(id)
    await registrar.setToken(id, "aa")
    await registrar.memoCreated(id)
    await registrar.handOver(id)
    #expect(await client.activityTokens[id] == "aa")

    await registrar.setToken(id, "bb")
    #expect(await client.activityTokens[id] == "bb")

    registrar.finish(id)
    await registrar.setToken(id, "cc")
    #expect(await client.activityTokens[id] == "bb", "nothing is sent for an activity that has ended")
    #expect(!registrar.isTracking(id))
  }

  @Test("a token that arrives only after the hand-over is still sent")
  func tokenAfterTheHandOver() async throws {
    let id = MemoID().wireID
    await client.seed(MemoFactory.detail(MemoFactory.memo(id)))
    let registrar = registrar()
    registrar.begin(id)
    await registrar.memoCreated(id)
    await registrar.handOver(id)
    await registrar.setToken(id, "aa")
    #expect(await client.activityTokens[id] == "aa")
  }
}
