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
      id: id, mode: .auto, device: "iphone", startedAt: Self.now, state: .notified, transcript: transcript,
      route: route, createdAt: Self.now, updatedAt: Self.now)
  }

  @Test("a finished memo posts one notification: the route as title, the headline as body")
  func posts() async {
    let poster = RecordingNotificationPoster()
    let notifier = MemoNotifier(poster: poster, lookup: { Self.memo($0) })
    await notifier.memoDone(id: "a")
    #expect(await poster.posted == [MemoNotification(memoID: "a", title: "Journal", body: "Buy oat milk")])
  }

  @Test("the same memo announced twice (a replayed event) posts once")
  func dedupes() async {
    let poster = RecordingNotificationPoster()
    let notifier = MemoNotifier(poster: poster, lookup: { Self.memo($0) })
    await notifier.memoDone(id: "a")
    await notifier.memoDone(id: "a")
    await notifier.memoDone(id: "b")
    #expect(await poster.posted.map(\.memoID) == ["a", "b"])
  }

  @Test("without permission nothing is posted, and the memo is not looked up")
  func denied() async {
    let poster = RecordingNotificationPoster(allowed: false)
    var lookups = 0
    let notifier = MemoNotifier(
      poster: poster,
      lookup: { _ in
        lookups += 1
        return nil
      })
    await notifier.memoDone(id: "a")
    #expect(await poster.posted.isEmpty && lookups == 0)
  }

  @Test("a memo the lookup cannot find, or one that was deleted, posts nothing")
  func missing() async {
    let poster = RecordingNotificationPoster()
    var gone = Self.memo("b")
    gone.deletedAt = Self.now
    let notifier = MemoNotifier(poster: poster, lookup: { $0 == "b" ? gone : nil })
    await notifier.memoDone(id: "a")
    await notifier.memoDone(id: "b")
    #expect(await poster.posted.isEmpty)
  }
}
