import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import Iris

@MainActor
@Suite("StartMemoIntent")
struct StartMemoIntentTests {
  private func waitFor(seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
    for _ in 0..<Int(seconds * 100) {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
  }

  @Test("performing the intent records a take in auto mode and requests the Live Activity")
  func performStartsTheTakeAndTheActivity() async throws {
    let root = CompositionRoot(arguments: ["-IrisFakeCapture"], credentials: InMemoryCredentialStore())
    #expect(CaptureIntents.handler === root)
    let activity = try #require(root.fakeLiveActivity)

    _ = try await StartMemoIntent().perform()

    let starts = await activity.starts
    #expect(starts.count == 1)
    #expect(starts.first?.mode == .auto)
    #expect(await activity.phases == [.recording])

    // The silent microphone feeds the take; stopping finishes the memo and the outbox sends it.
    let result = try #require(try await root.stopMemo())
    #expect(result.segmentCount >= 1)
    #expect(await waitFor { await activity.handedOver })
    let phases = await activity.phases
    #expect(phases.first == .recording && phases.contains(.uploading) && phases.last == .processing)
    #expect(await !activity.ended, "a sent memo's activity is left to the server's pushes, not ended")
    #expect(await root.outbox.queuedItems().isEmpty)
  }

  @Test("the intent refuses when no server is saved")
  func notConfigured() async {
    let root = CompositionRoot(arguments: [], credentials: InMemoryCredentialStore())
    await #expect(throws: StartMemoError.self) { try await root.startMemo() }
  }

  @Test("the intent says so when the app has not registered a handler")
  func noHandler() async {
    CaptureIntents.handler = nil
    await #expect(throws: StartMemoError.self) { _ = try await StartMemoIntent().perform() }
  }
}

@MainActor
@Suite("Live Activity phases of a take")
struct TakeLiveActivityTests {
  let client = FakeAPIClient(now: { MemoFactory.now })

  private func waitFor(seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
    for _ in 0..<Int(seconds * 100) {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
  }

  /// A take of a few seconds, stopped; the Live Activity follows it.
  private func takeAndStop(
    _ rig: OutboxRig, _ activity: RecordingLiveActivity,
    request: TakeRequest = TakeRequest(mode: "auto", title: "Voice memo")
  ) async throws -> (TakeLiveActivityCoordinator, MemoID) {
    let coordinator = TakeLiveActivityCoordinator(activity: activity, stack: rig.stack, created: rig.created)
    let session = try await rig.stack.session()
    let id = try await session.start(request)
    await coordinator.begin(memoID: id, mode: .auto, startedAt: MemoFactory.now)
    await rig.capture.recordWithoutClock(seconds: 3)
    _ = try await session.stop()
    return (coordinator, id)
  }

  @Test("recording, paused by an interruption, uploading, then processing; the server's pushes take over")
  func phases() async throws {
    let rig = OutboxRig(client: client)
    let activity = RecordingLiveActivity()
    let coordinator = TakeLiveActivityCoordinator(activity: activity, stack: rig.stack, created: rig.created)
    let session = try await rig.stack.session()
    let id = try await session.start(TakeRequest(mode: "auto", title: "Voice memo"))
    await coordinator.begin(memoID: id, mode: .auto, startedAt: MemoFactory.now)

    await rig.capture.recordWithoutClock(seconds: 3)
    await rig.capture.interrupt()
    #expect(await waitFor { await activity.phases.contains(.paused) })
    await rig.capture.endInterruption()
    await rig.capture.recordWithoutClock(seconds: 2)
    _ = try await session.stop()
    #expect(await rig.drain())
    await coordinator.finished()

    let phases = await activity.phases
    #expect(phases.first == .recording)
    #expect(phases.contains(.paused) && phases.contains(.uploading))
    #expect(phases.last == .processing)
    #expect(await activity.handedOver)
    #expect(await !activity.ended)
    #expect(await activity.memoCreatedCount == 1, "the push token is registered once the server has the memo")
    #expect(await activity.starts.map(\.memoID) == [id.wireID])
  }

  @Test("a retryable failure keeps the activity on uploading; once the memo is sent it moves on")
  func retryableFailureDoesNotEndTheActivity() async throws {
    let rig = OutboxRig(client: client)
    await client.enqueueFailure(.transport(.notConnectedToInternet), for: .createMemo)
    let activity = RecordingLiveActivity()
    let (coordinator, _) = try await takeAndStop(rig, activity)

    // Offline: the item is failed with a retry coming. The follower must still be waiting.
    #expect(
      await waitFor {
        await rig.service.queuedItems().contains { if case .failed(let at, _) = $0.state { at != nil } else { false } }
      })
    try await Task.sleep(for: .milliseconds(100))
    #expect(await activity.phases.last == .uploading)
    #expect(await !activity.ended && !activity.handedOver)

    await rig.clock.advance(by: 2)
    #expect(await rig.drain())
    await coordinator.finished()
    #expect(await activity.phases.last == .processing)
    #expect(await activity.handedOver && !activity.ended)
    #expect(await activity.memoCreatedCount == 1)
  }

  @Test("a stall ends the activity as failed, kept for a while")
  func stallEndsTheActivity() async throws {
    let rig = OutboxRig(client: client)
    let activity = RecordingLiveActivity()
    // An unknown thread is a 404: the server will say it again, so the item stalls.
    let (coordinator, _) = try await takeAndStop(
      rig, activity, request: TakeRequest(mode: "hermes", threadID: "gone", title: "Voice reply"))
    await coordinator.finished()

    let ends = await activity.ends
    #expect(ends.count == 1)
    #expect(ends.first?.dismissal == .later)
    #expect(ends.first?.finalState?.phase == .failed)
    #expect(await !activity.handedOver)
    #expect(await !activity.phases.contains(.processing))
  }

  @Test("discarding the queued take ends the activity at once")
  func discardEndsTheActivity() async throws {
    let rig = OutboxRig(client: client)
    await client.enqueueFailure(.transport(.timedOut), for: .createMemo)
    let activity = RecordingLiveActivity()
    let (coordinator, id) = try await takeAndStop(rig, activity)
    #expect(await waitFor { await rig.service.queuedItems().first != nil })

    await rig.service.discard(id: id.wireID)
    await coordinator.finished()
    #expect(await activity.ends == [.init(finalState: nil, dismissal: .immediate)])
    #expect(await !activity.handedOver)
  }

  @Test("at launch the coordinator asks for the activities a client phase left behind to be ended")
  func orphansAreSwept() async {
    let rig = OutboxRig(client: client)
    let activity = RecordingLiveActivity()
    let coordinator = TakeLiveActivityCoordinator(activity: activity, stack: rig.stack, created: rig.created)
    await coordinator.endOrphans()
    #expect(await activity.orphanSweeps == 1)
  }

  @Test("only the phases the device sets are client phases")
  func clientPhases() {
    #expect(LiveActivityPhase.allCases.filter(\.isClientPhase) == [.recording, .paused, .uploading])
  }
}

/// A store that cannot be read for its first `failures` loads (a file unreadable before the first unlock, say), then works.
private actor FlakyStore: OutboxStore {
  struct Unreadable: Error {}

  private var failures: Int
  private var record = OutboxRecord()
  private(set) var saves = 0

  init(failures: Int) {
    self.failures = failures
  }

  func load() throws -> OutboxRecord {
    if failures > 0 {
      failures -= 1
      throw Unreadable()
    }
    return record
  }

  func save(_ record: OutboxRecord) {
    self.record = record
    saves += 1
  }

  var items: [OutboxItem] { record.items }
}

@MainActor
@Suite("The queue that cannot be opened")
struct UnavailableQueueTests {
  let client = FakeAPIClient(now: { MemoFactory.now })

  private func submission(_ text: String = "hello") -> TextSubmission {
    TextSubmission(id: MemoID(), mode: .chat, text: text, threadId: nil, startedAt: MemoFactory.now)
  }

  @Test("while the store cannot be read nothing is accepted, and nothing is queued into a throwaway list")
  func refusesInsteadOfQueueingInMemory() async {
    let store = FlakyStore(failures: 1)
    let rig = OutboxRig(client: client, store: store)

    #expect(await rig.service.submitText(submission()) == .refused)
    #expect(await client.calls.isEmpty, "the memo was not sent either: it stays with the caller")
    #expect(await store.saves == 0)
    #expect(await store.items.isEmpty)
    #expect(await rig.service.queuedItems().isEmpty)
  }

  @Test("the next call tries the real store again, and accepts writes once it opens")
  func retriesTheRealStore() async {
    let store = FlakyStore(failures: 2)
    let rig = OutboxRig(client: client, store: store)

    #expect(await rig.service.submitText(submission()) == .refused)
    await rig.service.resume()  // second attempt: still unreadable
    #expect(await rig.service.submitText(submission("third")) != .refused)
    await client.enqueueFailure(.transport(.notConnectedToInternet), for: .createTextMemo)
    #expect(await rig.service.submitText(submission("offline")) == .queued)
    let stored = await store.items
    #expect(stored.map(\.title) == ["offline"], "the queue lives in the real store")
  }

  @Test("Settings says the outbox is closed, and clears it once it opens")
  func settingsShowsIt() async {
    let rig = OutboxRig(client: client, store: FlakyStore(failures: 1))
    let settings = SettingsModel(client: client, queue: rig.service)
    await settings.load()
    #expect(settings.queueUnavailable)
    await settings.load()
    #expect(!settings.queueUnavailable)
  }

  @Test("the composer keeps the text and says why when the outbox refused it")
  func composerKeepsTheText() async {
    let rig = OutboxRig(client: client, store: FlakyStore(failures: 1))
    let composer = ComposerModel(request: ComposerRequest(), outbox: rig.service, now: { MemoFactory.now })
    composer.text = "do not lose me"

    #expect(await composer.send() == nil)
    #expect(composer.failure != nil && composer.text == "do not lose me")
    #expect(await composer.send() != nil, "the retry finds the store open")
    #expect(composer.failure == nil)
  }

  @Test("a voice take cannot start while the outbox is closed")
  func voiceCannotStart() async {
    let rig = OutboxRig(client: client, store: FlakyStore(failures: 1))
    let voice = rig.voice()
    await #expect(throws: CaptureStackError.self) {
      try await voice.begin(VoiceReplyRequest(threadId: "t", mode: .hermes))
    }
  }
}
