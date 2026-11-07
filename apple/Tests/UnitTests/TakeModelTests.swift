import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import Iris

/// The in-app take on the fake stack: start from anywhere, minimize to the banner, pause, stop, discard.
extension CaptureHandlerSuites {
  @MainActor
  @Suite("Take model")
  struct TakeModelTests {
    private func waitFor(seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
      for _ in 0..<Int(seconds * 100) {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
      }
      return await condition()
    }

    private func make() -> (CompositionRoot, Task<Void, Never>) {
      let root = CompositionRoot(arguments: ["-IrisFakeCapture"], credentials: InMemoryCredentialStore())
      let take = root.take
      return (root, Task { await take.run() })
    }

    @Test("starting opens the take screen; minimizing leaves the banner; stopping sends the memo")
    func startMinimizeStop() async throws {
      let (root, follower) = make()
      defer { follower.cancel() }
      let take = root.take
      #expect(take.canStart && !take.isActive)

      await take.start()
      #expect(await waitFor { take.isActive && take.showsFull })
      #expect(take.modeTitle == "Hermes" && take.inputName != nil)

      take.showsFull = false
      #expect(take.isActive, "the take goes on behind the banner")

      await take.stop()
      #expect(await waitFor { !take.isActive })
      #expect(!take.showsFull)
      #expect(take.failure == nil)
      #expect(await waitFor { await root.fakeLiveActivity?.handedOver == true }, "the memo reaches the server")
    }

    @Test("the Transcribe start hands the transcribe mode to the controller")
    func transcribeStart() async throws {
      let (root, follower) = make()
      defer { follower.cancel() }
      let take = root.take

      await take.start(mode: .transcribe)
      #expect(await waitFor { take.isActive })
      #expect(take.modeTitle == "Transcribe")
      #expect(await root.fakeLiveActivity?.starts.first?.mode == .transcribe)
      await take.discard()
      #expect(await waitFor { !take.isActive })
    }

    @Test("pausing freezes the timer and resuming moves its start forward by the pause")
    func pauseAndResume() async throws {
      let (root, follower) = make()
      defer { follower.cancel() }
      let take = root.take
      await take.start()
      #expect(await waitFor { take.isActive })

      await take.togglePause()
      #expect(await waitFor { take.isPaused })
      let frozen = try #require(take.timerFrozenAt)
      let startWhilePaused = try #require(take.timerStart)

      try await Task.sleep(for: .milliseconds(300))
      await take.togglePause()
      #expect(await waitFor { !take.isPaused })
      #expect(take.timerFrozenAt == nil)
      #expect(try #require(take.timerStart) > startWhilePaused, "the paused time is not counted")
      #expect(frozen <= Date())

      await take.discard()
      #expect(await waitFor { !take.isActive })
    }

    @Test("a second start is refused while a take runs")
    func oneTakeAtATime() async {
      let (root, follower) = make()
      defer { follower.cancel() }
      let take = root.take
      await take.start()
      #expect(await waitFor { take.isActive })
      #expect(!take.canStart)
      await take.discard()
    }

    @Test("discarding after the memo was created deletes it on the server and keeps it out of History")
    func discardHidesAndDeletes() async throws {
      let (root, follower) = make()
      defer { follower.cancel() }
      let take = root.take
      let api = try #require(root.fakeAPI)

      await take.start()
      #expect(await waitFor { take.isActive })
      // The silent microphone closes a segment every ten seconds of audio; wait for the memo to exist on the server.
      let id = try #require(take.state.memoID?.wireID)
      #expect(await waitFor(seconds: 30) { (try? await api.memo(id: id)) != nil })
      root.history.insert(try await api.memo(id: id).memo)  // what the created-memo hand-off does
      #expect(root.history.memos.contains { $0.id == id })

      await take.discard()
      #expect(await waitFor { !take.isActive })
      // The hand-off to History is asynchronous (an ordered stream), so it is awaited like the delete below.
      #expect(await waitFor { !root.history.memos.contains { $0.id == id } }, "the cancelled take is never shown")
      #expect(await waitFor { (try? await api.memo(id: id))?.memo.isDeleted == true })

      // A refresh and a late hand-off cannot bring it back.
      await root.history.load()
      root.history.insert(try await api.memo(id: id).memo)
      #expect(!root.history.memos.contains { $0.id == id })
    }

    private func firstTakeID(_ take: TakeModel) async -> String? {
      take.state.memoID?.wireID
    }
  }
}

/// The timer of the take screen and the banner: counts while the recorder runs, stands still while it is stopped (paused or
/// failed), and leaves the paused time out.
@MainActor
@Suite("Take timer")
struct TakeTimerTests {
  let client = FakeAPIClient(now: { MemoFactory.now })
  let started = Date(timeIntervalSince1970: 1_800_000_000)

  private func snapshot(_ phase: TakePhase, memo: MemoID) -> TakeState {
    var take = TakeState.idle
    take.phase = phase
    take.memoID = memo
    take.startedAt = started
    take.request = TakeRequest(mode: "hermes", title: "Voice memo")
    return take
  }

  private func model(clock: Clock) -> TakeModel {
    let rig = OutboxRig(client: client)
    let controller = TakeController(
      stack: rig.stack,
      liveActivity: TakeLiveActivityCoordinator(
        activity: RecordingLiveActivity(), stack: rig.stack, created: rig.created),
      outbox: rig.service, microphone: nil, canRecord: true, isConfigured: { true }, requestPermission: { true },
      preview: nil)
    return TakeModel(controller: controller, now: { clock.now })
  }

  /// A settable instant for the model's clock.
  final class Clock {
    var now: Date
    init(_ now: Date) { self.now = now }
  }

  @Test("a failed recorder freezes the timer at the instant it stopped, across further failed snapshots")
  func failureFreezes() throws {
    let clock = Clock(started.addingTimeInterval(10))
    let take = model(clock: clock)
    let memo = MemoID()
    take.apply(snapshot(.recording, memo: memo))
    #expect(take.timerFrozenAt == nil)

    clock.now = started.addingTimeInterval(25)
    take.apply(snapshot(.failed, memo: memo))
    #expect(take.timerFrozenAt == started.addingTimeInterval(25))

    clock.now = started.addingTimeInterval(60)
    take.apply(snapshot(.failed, memo: memo))
    #expect(take.timerFrozenAt == started.addingTimeInterval(25))
    #expect(take.timerStart == started)
  }

  @Test("a pause that turns into a failure keeps the instant of the pause")
  func pausedThenFailed() throws {
    let clock = Clock(started.addingTimeInterval(10))
    let take = model(clock: clock)
    let memo = MemoID()
    take.apply(snapshot(.recording, memo: memo))
    clock.now = started.addingTimeInterval(20)
    take.apply(snapshot(.paused, memo: memo))
    clock.now = started.addingTimeInterval(40)
    take.apply(snapshot(.failed, memo: memo))
    #expect(take.timerFrozenAt == started.addingTimeInterval(20))
  }

  @Test("the time spent paused moves the timer's start forward")
  func pausedTimeIsLeftOut() throws {
    let clock = Clock(started.addingTimeInterval(10))
    let take = model(clock: clock)
    let memo = MemoID()
    take.apply(snapshot(.recording, memo: memo))
    clock.now = started.addingTimeInterval(20)
    take.apply(snapshot(.paused, memo: memo))
    clock.now = started.addingTimeInterval(50)
    take.apply(snapshot(.recording, memo: memo))
    #expect(take.timerFrozenAt == nil)
    #expect(take.timerStart == started.addingTimeInterval(30))

    clock.now = started.addingTimeInterval(60)
    take.apply(snapshot(.failed, memo: memo))
    #expect(take.timerFrozenAt == started.addingTimeInterval(60))
    #expect(take.timerStart == started.addingTimeInterval(30))
  }

  @Test("a new take starts with a running timer")
  func newTakeResets() throws {
    let clock = Clock(started.addingTimeInterval(10))
    let take = model(clock: clock)
    let first = MemoID()
    take.apply(snapshot(.recording, memo: first))
    clock.now = started.addingTimeInterval(20)
    take.apply(snapshot(.failed, memo: first))
    #expect(take.timerFrozenAt != nil)

    take.apply(snapshot(.recording, memo: MemoID()))
    #expect(take.timerFrozenAt == nil)
    #expect(take.timerStart == started)
  }
}
