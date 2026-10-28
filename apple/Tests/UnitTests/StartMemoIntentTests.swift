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
    #expect(await waitFor { await activity.ended })
    let phases = await activity.phases
    #expect(phases.first == .recording && phases.contains(.uploading) && phases.last == .processing)
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
  @Test("recording, paused by an interruption, uploading, then processing; the server's pushes take over")
  func phases() async throws {
    let rig = OutboxRig(client: FakeAPIClient(now: { MemoFactory.now }))
    let activity = RecordingLiveActivity()
    let coordinator = TakeLiveActivityCoordinator(activity: activity, stack: rig.stack)
    let session = await rig.stack.session()
    let id = try await session.start(TakeRequest(mode: "auto", title: "Voice memo"))
    await coordinator.begin(memoID: id, mode: .auto, startedAt: MemoFactory.now)

    await rig.capture.recordWithoutClock(seconds: 3)
    await rig.capture.interrupt()
    for _ in 0..<500 where !(await activity.phases.contains(.paused)) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await activity.phases.contains(.paused))
    await rig.capture.endInterruption()
    await rig.capture.recordWithoutClock(seconds: 2)
    _ = try await session.stop()
    #expect(await rig.drain())
    await coordinator.finished()

    let phases = await activity.phases
    #expect(phases.first == .recording)
    #expect(phases.contains(.paused) && phases.contains(.uploading))
    #expect(phases.last == .processing)
    #expect(await activity.ended)
    #expect(await activity.starts.map(\.memoID) == [id.wireID])
  }
}
