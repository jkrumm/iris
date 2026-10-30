import Foundation
import IrisCore
import Testing

@testable import IrisMac

@MainActor
@Suite("Memo notifier")
struct MemoNotifierTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  private static func memo(_ id: String, route: String? = "journal", transcript: String = "Buy oat milk") -> Memo {
    Memo(
      id: id, mode: .auto, device: "iphone", startedAt: now, state: .notified, transcript: transcript,
      route: route, createdAt: now, updatedAt: now)
  }

  private func notifier(
    _ poster: RecordingNotificationPoster, lookup: @escaping (String) async -> Memo? = { Self.memo($0) }
  ) -> MemoNotifier {
    MemoNotifier(poster: poster, lookup: lookup, retryDelays: [.zero, .zero])
  }

  @Test("a finished memo posts one notification: the route as title, the headline as body")
  func posts() async {
    let poster = RecordingNotificationPoster()
    await notifier(poster).memoDone(id: "a")
    #expect(await poster.posted == [MemoNotification(memoID: "a", title: "Journal", body: "Buy oat milk")])
  }

  @Test("the same memo announced twice (a replayed event) posts once; two calls at the same time post once")
  func dedupes() async {
    let poster = RecordingNotificationPoster()
    let notifier = notifier(poster)
    async let first: Void = notifier.memoDone(id: "a")
    async let second: Void = notifier.memoDone(id: "a")
    _ = await (first, second)
    await notifier.memoDone(id: "a")
    await notifier.memoDone(id: "b")
    #expect(await poster.posted.map(\.memoID) == ["a", "b"])
  }

  @Test("a deleted memo, or one the lookup never finds, posts nothing")
  func missing() async {
    let poster = RecordingNotificationPoster()
    var gone = Self.memo("b")
    gone.deletedAt = Self.now
    let notifier = notifier(poster) { $0 == "b" ? gone : nil }
    await notifier.memoDone(id: "a")
    await notifier.memoDone(id: "b")
    #expect(await poster.posted.isEmpty)
  }

  @Test(
    "a failed lookup is retried within the call, and a lookup that keeps failing leaves the memo for the next event")
  func lookupFailures() async {
    let poster = RecordingNotificationPoster()
    var lookups = 0
    var available = false
    let notifier = notifier(poster) { id in
      lookups += 1
      return lookups >= 3 || available ? Self.memo(id) : nil
    }
    await notifier.memoDone(id: "a")
    let first = await poster.posted.map(\.memoID)
    #expect(lookups == 3 && first == ["a"])

    lookups = -100
    await notifier.memoDone(id: "b")
    #expect(await poster.posted.map(\.memoID) == ["a"])
    available = true
    await notifier.memoDone(id: "b")
    #expect(await poster.posted.map(\.memoID) == ["a", "b"])
  }

  @Test("a post the system refuses is retried, and is not remembered as announced")
  func postFailures() async {
    let poster = RecordingNotificationPoster()
    await poster.failNextPosts(2)
    let notifier = notifier(poster)
    await notifier.memoDone(id: "a")
    #expect(await poster.posted.map(\.memoID) == ["a"])

    await poster.failNextPosts(3)
    await notifier.memoDone(id: "b")
    #expect(await poster.posted.map(\.memoID) == ["a"])
    await notifier.memoDone(id: "b")
    #expect(await poster.posted.map(\.memoID) == ["a", "b"])
  }

  @Test(
    "a denial is read again for every memo: enabling notifications in System Settings takes effect without a relaunch")
  func denialIsNotCached() async {
    let poster = RecordingNotificationPoster(permission: .denied)
    let notifier = notifier(poster)
    await notifier.memoDone(id: "a")
    let (posted, requests) = (await poster.posted, await poster.requests)
    #expect(posted.isEmpty && requests == 0)

    await poster.setPermission(.allowed)
    await notifier.memoDone(id: "a")
    #expect(await poster.posted.map(\.memoID) == ["a"])
  }

  @Test("an unanswered prompt holds finished memos back, asks once, and releases them when the user answers")
  func promptQueuesMemos() async {
    let poster = RecordingNotificationPoster(permission: .undetermined, holdsPrompt: true)
    let notifier = notifier(poster)
    notifier.requestPermissionIfNeeded()
    let pending = Task { await notifier.memoDone(id: "a") }
    let other = Task { await notifier.memoDone(id: "b") }
    #expect(await eventually { await poster.requests == 1 })
    #expect(await poster.posted.isEmpty)

    await poster.answerPrompt(true)
    await pending.value
    await other.value
    let (posted, requests) = (await poster.posted.map(\.memoID).sorted(), await poster.requests)
    #expect(posted == ["a", "b"] && requests == 1)
  }

  @Test("a refused prompt posts nothing")
  func promptRefused() async {
    let poster = RecordingNotificationPoster(permission: .undetermined, holdsPrompt: true)
    let notifier = notifier(poster)
    let pending = Task { await notifier.memoDone(id: "a") }
    #expect(await eventually { await poster.requests == 1 })
    await poster.answerPrompt(false)
    await pending.value
    #expect(await poster.posted.isEmpty)
  }

  @Test("reset forgets what was announced: the next server's memos start clean")
  func reset() async {
    let poster = RecordingNotificationPoster()
    let notifier = notifier(poster)
    await notifier.memoDone(id: "a")
    notifier.reset()
    await notifier.memoDone(id: "a")
    #expect(await poster.posted.count == 2)
  }
}
