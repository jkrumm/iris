import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import Iris

/// The in-app take on the fake stack: start from anywhere, minimize to the banner, pause, stop, discard.
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
    #expect(take.modeTitle == "Auto" && take.inputName != nil)

    take.showsFull = false
    #expect(take.isActive, "the take goes on behind the banner")

    await take.stop()
    #expect(await waitFor { !take.isActive })
    #expect(!take.showsFull)
    #expect(take.failure == nil)
    #expect(await waitFor { await root.fakeLiveActivity?.handedOver == true }, "the memo reaches the server")
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
    #expect(!root.history.memos.contains { $0.id == id }, "the cancelled take is never shown")
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
