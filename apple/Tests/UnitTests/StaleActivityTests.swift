import Foundation
import IrisCore
import Testing

@testable import Iris

private nonisolated let now = MemoFactory.now

private func activity(
  _ id: String = "m1", phase: LiveActivityPhase = .processing, age: TimeInterval = 120, remote: Bool = false
) -> HandedOverActivity {
  HandedOverActivity(memoID: id, phase: phase, startedAt: now.addingTimeInterval(-age), remoteUpdates: remote)
}

@Suite("StaleActivityRule")
struct StaleActivityRuleTests {
  @Test("without a push token an activity ends once the server is done with its memo, on that result")
  func endsOnTheResult() {
    for (state, phase) in [
      (MemoState.notified, LiveActivityPhase.done), (.failed, .failed), (.needsRoute, .needsRoute),
    ] {
      let verdict = StaleActivityRule.verdict(for: activity(), memo: MemoFactory.memo("m1", state: state), now: now)
      guard case .end(let final?) = verdict else {
        Issue.record("\(state) should end the activity")
        continue
      }
      #expect(final.phase == phase)
    }
  }

  @Test("a memo still in the pipeline keeps its activity")
  func keepsWhilePipelineRuns() {
    for state in [MemoState.receiving, .received, .transcribed, .routed, .acted, .summarized] {
      #expect(StaleActivityRule.verdict(for: activity(), memo: MemoFactory.memo("m1", state: state), now: now) == .keep)
    }
  }

  @Test("with a push token the server owns the activity, finished memo or not")
  func serverOwnsIt() {
    let verdict = StaleActivityRule.verdict(
      for: activity(remote: true), memo: MemoFactory.memo("m1", state: .notified), now: now)
    #expect(verdict == .keep)
  }

  @Test("older than the bound ends it, token or not, memo known or not")
  func oldActivitiesEnd() {
    let old = StaleActivityRule.maxAge + 1
    for remote in [true, false] {
      #expect(
        StaleActivityRule.verdict(for: activity(age: old, remote: remote), memo: nil, now: now) == .end(final: nil))
    }
    let justUnder = StaleActivityRule.maxAge - 1
    #expect(StaleActivityRule.verdict(for: activity(age: justUnder), memo: nil, now: now) == .keep)
  }

  @Test("a memo the server does not have ends its activity")
  func goneEnds() {
    #expect(StaleActivityRule.verdict(for: activity(remote: true), memo: nil, gone: true, now: now) == .end(final: nil))
  }

  @Test("an unreachable server keeps a young activity")
  func offlineKeeps() {
    #expect(StaleActivityRule.verdict(for: activity(), memo: nil, now: now) == .keep)
  }

  @Test("a starting take displaces finished activities and ones nothing updates, never one the server drives")
  func newTakeTakesTheIsland() {
    #expect(StaleActivityRule.yieldsToNewTake(activity(phase: .done, remote: true)))
    #expect(StaleActivityRule.yieldsToNewTake(activity(phase: .failed)))
    #expect(StaleActivityRule.yieldsToNewTake(activity(phase: .processing, remote: false)))
    #expect(StaleActivityRule.yieldsToNewTake(activity(phase: .needsRoute, remote: false)))
    #expect(!StaleActivityRule.yieldsToNewTake(activity(phase: .processing, remote: true)))
    #expect(!StaleActivityRule.yieldsToNewTake(activity(phase: .recording)))
  }
}

/// The platform's activities, in memory.
private final class FakeCatalog: ActivityCatalog, @unchecked Sendable {
  var activities: [HandedOverActivity]
  /// Runs on every listing (a test cancels the asking task from here).
  var onList: () -> Void = {}
  var ended: [(id: String, final: LiveActivityContentState?, dismissal: ActivityDismissal)] = []

  init(_ activities: [HandedOverActivity]) { self.activities = activities }

  func handedOverActivities() -> [HandedOverActivity] {
    onList()
    return activities
  }

  func end(memoID: String, finalState: LiveActivityContentState?, dismissal: ActivityDismissal) async {
    ended.append((memoID, finalState, dismissal))
    activities.removeAll { $0.memoID == memoID }
  }
}

@Suite("StaleActivitySweeper")
struct StaleActivitySweeperTests {
  let client = FakeAPIClient(now: { MemoFactory.now })

  private func sweeper(_ catalog: FakeCatalog, sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in })
    -> StaleActivitySweeper
  {
    StaleActivitySweeper(catalog: catalog, client: client, now: { now }, sleep: sleep)
  }

  @Test("launch: ends the activities whose memo is finished or gone or too old, keeps the rest")
  func launchSweep() async {
    await client.seed(MemoFactory.detail(MemoFactory.memo("done", state: .notified, replyText: "hi")))
    await client.seed(MemoFactory.detail(MemoFactory.memo("busy", state: .routed)))
    await client.seed(MemoFactory.detail(MemoFactory.memo("pushed", state: .notified)))
    let catalog = FakeCatalog([
      activity("done"), activity("busy"), activity("pushed", remote: true), activity("gone"),
      activity("old", age: StaleActivityRule.maxAge + 60),
    ])

    let toFollow = await sweeper(catalog).sweep()

    #expect(toFollow == ["busy"], "kept without a push token: nothing else will end it, so it is followed")
    #expect(Set(catalog.ended.map(\.id)) == ["done", "gone", "old"])
    #expect(catalog.ended.allSatisfy { $0.dismissal == .immediate })
    #expect(Set(catalog.activities.map(\.memoID)) == ["busy", "pushed"])
  }

  @Test("an activity of another server is not asked about: that server's 404 does not end it")
  func foreignServerActivityStays() async {
    let catalog = FakeCatalog([
      HandedOverActivity(
        memoID: "theirs", phase: .processing, startedAt: now.addingTimeInterval(-120), remoteUpdates: false,
        serverKey: "old"),
      HandedOverActivity(
        memoID: "mine", phase: .processing, startedAt: now.addingTimeInterval(-120), remoteUpdates: false,
        serverKey: "new"),
      activity("legacy"),
    ])
    let sweeper = StaleActivitySweeper(
      catalog: catalog, client: client, serverKey: { "new" }, now: { now }, sleep: { _ in })

    let toFollow = await sweeper.sweep()

    // `mine` and `legacy` (no key) are unknown to the fake server and end; `theirs` is not this server's to judge.
    #expect(Set(catalog.ended.map(\.id)) == ["mine", "legacy"])
    #expect(toFollow == ["theirs"])
  }

  @Test("a sweep cancelled by a connection change ends and follows nothing")
  func cancelledSweepSettlesNothing() async {
    await client.seed(MemoFactory.detail(MemoFactory.memo("done", state: .notified)))
    await client.seed(MemoFactory.detail(MemoFactory.memo("busy", state: .routed)))
    let catalog = FakeCatalog([activity("done"), activity("busy")])
    // Cancelled while the sweep lists its activities, before any lookup answers.
    catalog.onList = { withUnsafeCurrentTask { $0?.cancel() } }
    let sweeper = sweeper(catalog)

    let followed = await Task { await sweeper.sweep() }.value

    #expect(followed.isEmpty)
    #expect(catalog.ended.isEmpty)
  }

  @Test("a take starting ends the finished and the stuck activities, not the running ones")
  func makeRoom() async {
    let catalog = FakeCatalog([
      activity("finished", phase: .done, remote: true), activity("stuck"), activity("driven", remote: true),
    ])

    await sweeper(catalog).makeRoomForTake()

    #expect(Set(catalog.ended.map(\.id)) == ["finished", "stuck"])
    #expect(catalog.activities.map(\.memoID) == ["driven"])
  }

  @Test("following polls until the server is done, then ends on the result and keeps it on the Lock Screen")
  func followEndsWhenTheMemoFinishes() async {
    await client.seed(MemoFactory.detail(MemoFactory.memo("m1", state: .summarized)))
    let catalog = FakeCatalog([activity("m1")])
    let polls = PollCounter()
    let client = client
    let sweeper = sweeper(catalog) { _ in
      if await polls.next() == 2 {
        await client.seed(MemoFactory.detail(MemoFactory.memo("m1", state: .notified, replyText: "hi")))
      }
    }

    await sweeper.follow(memoID: "m1")

    #expect(catalog.ended.count == 1)
    #expect(catalog.ended.first?.final?.phase == .done)
    #expect(catalog.ended.first?.dismissal == .later)
    #expect(await polls.count == 2)
  }

  @Test("a kept tokenless activity of an earlier run is followed and ends on the memo's result")
  func relaunchedProcessingActivityEnds() async {
    await client.seed(MemoFactory.detail(MemoFactory.memo("m1", state: .summarized)))
    let catalog = FakeCatalog([activity("m1")])
    let polls = PollCounter()
    let client = client
    let sweeper = sweeper(catalog) { _ in
      if await polls.next() == 1 {
        await client.seed(MemoFactory.detail(MemoFactory.memo("m1", state: .notified)))
      }
    }

    let toFollow = await sweeper.sweep()
    #expect(toFollow == ["m1"] && catalog.ended.isEmpty)
    for memoID in toFollow { await sweeper.follow(memoID: memoID) }

    #expect(catalog.ended.map(\.id) == ["m1"])
    #expect(catalog.ended.first?.final?.phase == .done)
  }

  @Test("a follower cancelled during its lookup never ends the activity")
  func cancelledFollowerEndsNothing() async {
    await client.seed(MemoFactory.detail(MemoFactory.memo("m1", state: .notified)))
    let catalog = FakeCatalog([activity("m1")])
    // The first listing is the follower's own: cancel it there, so the memo it then reads is finished but nobody wants it ended.
    catalog.onList = { withUnsafeCurrentTask { $0?.cancel() } }
    let sweeper = sweeper(catalog)

    await Task { await sweeper.follow(memoID: "m1") }.value

    #expect(catalog.ended.isEmpty)
  }

  @Test("following stops when the activity is gone, or when the server hands it pushes")
  func followStops() async {
    let catalog = FakeCatalog([])
    await sweeper(catalog).follow(memoID: "m1")
    #expect(catalog.ended.isEmpty)

    await client.seed(MemoFactory.detail(MemoFactory.memo("m2", state: .notified)))
    let pushed = FakeCatalog([activity("m2", remote: true)])
    let aged = StaleActivitySweeper(
      catalog: pushed, client: client, now: { now.addingTimeInterval(StaleActivityRule.maxAge + 120) }, sleep: { _ in })
    await aged.follow(memoID: "m2")
    #expect(pushed.ended.map(\.id) == ["m2"], "the age bound ends it even with a token, so the poll terminates")
  }

  @Test("a memo the server does not have ends the followed activity at once, without a result")
  func followGone() async {
    let catalog = FakeCatalog([activity("ghost")])
    await sweeper(catalog).follow(memoID: "ghost")
    #expect(catalog.ended.count == 1)
    #expect(catalog.ended.first?.final == nil)
    #expect(catalog.ended.first?.dismissal == .immediate)
  }
}

private actor PollCounter {
  private(set) var count = 0
  func next() -> Int {
    count += 1
    return count
  }
}
