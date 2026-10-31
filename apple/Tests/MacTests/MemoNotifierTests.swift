import Foundation
import IrisCore
import Testing

@testable import IrisMac

@MainActor
@Suite("Memo notifier")
struct MemoNotifierTests {
  static let now = Date(timeIntervalSince1970: 1_800_000_000)

  static let secret = "my secret transcript about the bank account"

  static func memo(
    _ id: String, state: MemoState = .notified, route: String? = "journal",
    summary: MemoSummary? = MemoSummary(headline: "Buy oat milk", detail: "d", spoken: "s"), started: Date = now
  ) -> Memo {
    Memo(
      id: id, mode: .auto, device: "iphone", startedAt: started, state: state, transcript: secret, route: route,
      replyText: "the reply " + secret, summary: summary, createdAt: now, updatedAt: now)
  }

  private func notifier(
    _ poster: RecordingNotificationPoster, lookup: @escaping (String) async -> Memo? = { Self.memo($0) }
  ) -> MemoNotifier {
    MemoNotifier(poster: poster, connectionID: "c1", lookup: lookup, retryDelays: [.zero, .zero])
  }

  @Test("a finished memo posts one notification: the route as title, the headline as body")
  func posts() async {
    let poster = RecordingNotificationPoster()
    let notifier = notifier(poster)
    await notifier.memoDone(id: "a")
    #expect(
      await poster.posted == [
        MemoNotification(memoID: "a", connectionID: notifier.connectionID, title: "Journal", body: "Buy oat milk")
      ])
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
    notifier.reset(connectionID: "c2")
    await notifier.memoDone(id: "a")
    #expect(await poster.posted.count == 2)
  }

  @Test(
    "a banner never carries the transcript, the reply or the park reason: parked and failed memos say generic words")
  func neverTheTranscript() {
    let noSummary = MemoNotifier.notification(for: Self.memo("a", summary: nil), connectionID: "c")
    #expect(noSummary == MemoNotification(memoID: "a", connectionID: "c", title: "Journal", body: "Done."))

    var parked = Self.memo("b", state: .needsRoute, route: nil, summary: nil)
    parked.routeReason = "Not sure whether \(Self.secret) means the tab dotfiles / claude."
    var failed = Self.memo("c", state: .failed, route: nil, summary: nil)
    failed.error = Self.secret
    failed.failedStep = .transcribe

    let parkedBanner = MemoNotifier.notification(for: parked, connectionID: "c")
    #expect(parkedBanner.title == "Where should this go?" && parkedBanner.body == "Open Iris to choose a route.")
    let failedBanner = MemoNotifier.notification(for: failed, connectionID: "c")
    #expect(failedBanner.title == "Memo failed" && failedBanner.body == "Open Iris to retry it.")

    for memo in [Self.memo("a", summary: nil), parked, failed] {
      let shown = MemoNotifier.notification(for: memo, connectionID: "c")
      #expect(!shown.title.contains("secret") && !shown.body.contains("secret"))
      #expect(!shown.body.contains("dotfiles") && !shown.body.contains("transcribe"))
    }
  }

  @Test(
    "a memo the server does not call done yet is not announced, and is not remembered: its own memo.done still posts")
  func notResultReady() async {
    let poster = RecordingNotificationPoster()
    var state = MemoState.acted
    let notifier = notifier(poster) { Self.memo($0, state: state) }
    await notifier.memoDone(id: "a")
    #expect(await poster.posted.isEmpty)
    state = .notified
    await notifier.memoDone(id: "a")
    #expect(await poster.posted.map(\.memoID) == ["a"])
  }

  @Test("a failed fetch never announces a cached copy: nothing posts until the server answers")
  func failedFetchPostsNothing() async {
    let poster = RecordingNotificationPoster()
    let notifier = notifier(poster) { _ in nil }
    await notifier.memoDone(id: "a")
    #expect(await poster.posted.isEmpty)
  }

  @Test("banners carry the connection they were posted for, and a server switch names a new one")
  func connectionBinding() async {
    let poster = RecordingNotificationPoster()
    let notifier = notifier(poster)
    let first = notifier.connectionID
    await notifier.memoDone(id: "a")
    notifier.reset(connectionID: "c2")
    await notifier.memoDone(id: "b")
    let posted = await poster.posted
    #expect(posted.map(\.connectionID) == [first, notifier.connectionID] && first != notifier.connectionID)
  }

  @Test("an event seen before a server switch is dropped when its task only runs after it")
  func staleGeneration() async {
    let poster = RecordingNotificationPoster()
    let notifier = notifier(poster)
    let seen = notifier.generation
    notifier.reset(connectionID: "c2")
    await notifier.memoDone(id: "a", generation: seen)
    #expect(await poster.posted.isEmpty)
    await notifier.memoDone(id: "a")
    #expect(await poster.posted.map(\.memoID) == ["a"])
  }

  @Test("a lookup that was in flight during a server switch posts nothing and leaves the id free on the new server")
  func switchDuringLookup() async {
    let poster = RecordingNotificationPoster()
    let (opened, open) = AsyncStream<Void>.makeStream()
    var started = false
    let notifier = notifier(poster) { id in
      started = true
      for await _ in opened { break }
      return Self.memo(id)
    }
    let pending = Task { await notifier.memoDone(id: "a") }
    #expect(await eventually { started })
    notifier.reset(connectionID: "c2")
    open.yield()
    open.finish()
    await pending.value
    #expect(await poster.posted.isEmpty)
    await notifier.memoDone(id: "a")
    #expect(await poster.posted.map(\.memoID) == ["a"])
  }

  @Test("three tries in all, then the id is forgotten: a later event for the memo may try again")
  func boundedRetries() async {
    let poster = RecordingNotificationPoster()
    await poster.failNextPosts(10)
    let notifier = notifier(poster)
    await notifier.memoDone(id: "a")
    #expect(await poster.posted.isEmpty)
    await poster.failNextPosts(0)
    await notifier.memoDone(id: "a")
    #expect(await poster.posted.map(\.memoID) == ["a"])
  }
}

/// Catch-up, transitions and the banner of a server that is gone (Wave 19 M1).
@MainActor
@Suite("Memo notifier: transitions, catch-up, switches")
struct MemoNotifierCatchUpTests {
  private static let now = MemoNotifierTests.now

  /// The server as a script: the memos the unfiltered fetch and the per-memo lookup answer from.
  @MainActor
  final class Server {
    var memos: [Memo] = []
    var fetches = 0

    func memo(_ id: String) -> Memo? { memos.first { $0.id == id } }

    func set(_ id: String, _ state: MemoState) {
      guard let index = memos.firstIndex(where: { $0.id == id }) else { return }
      memos[index].state = state
    }
  }

  private func rig(
    _ poster: RecordingNotificationPoster, _ server: Server
  ) -> MemoNotifier {
    let notifier = MemoNotifier(
      poster: poster, connectionID: "c1", lookup: { server.memo($0) }, retryDelays: [.zero, .zero])
    notifier.fetchRecent = {
      server.fetches += 1
      return server.memos
    }
    return notifier
  }

  private func event(_ id: String, _ state: MemoState) -> MemoEvent {
    MemoEvent(id: id, state: state, at: Self.now)
  }

  private func memo(_ id: String, _ state: MemoState, minutesAgo: Double = 0) -> Memo {
    MemoNotifierTests.memo(id, state: state, started: Self.now.addingTimeInterval(-minutesAgo * 60))
  }

  @Test("a failed memo is announced once, in generic words; a repeated event for it posts nothing")
  func failedOnce() async {
    let poster = RecordingNotificationPoster()
    let server = Server()
    server.memos = [memo("a", .failed)]
    let notifier = rig(poster, server)
    #expect(notifier.noteState(of: event("a", .failed)))
    await notifier.memoDone(id: "a")
    #expect(!notifier.noteState(of: event("a", .failed)))
    await notifier.memoDone(id: "a")
    let posted = await poster.posted
    #expect(posted.map(\.title) == ["Memo failed"] && posted.map(\.body) == ["Open Iris to retry it."])
  }

  @Test(
    "the transition is what counts: failed, retried, then notified is two banners; a running state clears the record")
  func transitions() async {
    let poster = RecordingNotificationPoster()
    let server = Server()
    server.memos = [memo("a", .failed)]
    let notifier = rig(poster, server)
    _ = notifier.noteState(of: event("a", .failed))
    await notifier.memoDone(id: "a")

    #expect(!notifier.noteState(of: event("a", .transcribed)))
    server.set("a", .notified)
    #expect(notifier.noteState(of: event("a", .notified)))
    await notifier.memoDone(id: "a")
    #expect(await poster.posted.map(\.title) == ["Memo failed", "Journal"])
    #expect(!notifier.noteState(of: event("a", .notified)))
  }

  @Test("a parked memo announces on entering needs_route, and again as done once it has been routed")
  func parkedThenDone() async {
    let poster = RecordingNotificationPoster()
    let server = Server()
    server.memos = [memo("a", .needsRoute)]
    let notifier = rig(poster, server)
    #expect(notifier.noteState(of: event("a", .needsRoute)))
    await notifier.memoDone(id: "a")
    #expect(!notifier.noteState(of: event("a", .needsRoute)))
    _ = notifier.noteState(of: event("a", .routed))
    server.set("a", .notified)
    #expect(notifier.noteState(of: event("a", .notified)))
    await notifier.memoDone(id: "a")
    #expect(await poster.posted.map(\.title) == ["Where should this go?", "Journal"])
  }

  @Test("the event's state is not the answer: a memo that moved on by the time it is fetched is judged by the fetch")
  func freshStateWins() async {
    let poster = RecordingNotificationPoster()
    let server = Server()
    server.memos = [memo("a", .acted)]
    let notifier = rig(poster, server)
    #expect(notifier.noteState(of: event("a", .failed)))
    await notifier.memoDone(id: "a")
    #expect(await poster.posted.isEmpty)
  }

  @Test("the first catch-up of a connection is the baseline: what already finished is not announced")
  func baselineIsSilent() async {
    let poster = RecordingNotificationPoster()
    let server = Server()
    server.memos = [memo("a", .notified, minutesAgo: 5), memo("b", .failed, minutesAgo: 4), memo("c", .needsRoute)]
    let notifier = rig(poster, server)
    #expect(!notifier.hasBaseline)
    await notifier.catchUp()
    #expect(notifier.hasBaseline && server.fetches == 1)
    await notifier.catchUp()
    #expect(await poster.posted.isEmpty)
  }

  @Test("a memo that finished, failed or parked while the stream was down is announced once on the next catch-up")
  func catchUpAnnouncesWhatHappenedMeanwhile() async {
    let poster = RecordingNotificationPoster()
    let server = Server()
    server.memos = [
      memo("a", .acted, minutesAgo: 3), memo("b", .routed, minutesAgo: 2), memo("c", .transcribed, minutesAgo: 1),
    ]
    let notifier = rig(poster, server)
    await notifier.catchUp()
    server.set("a", .notified)
    server.set("b", .needsRoute)
    server.set("c", .failed)
    await notifier.catchUp()
    let posted = await poster.posted
    #expect(Set(posted.map(\.memoID)) == ["a", "b", "c"] && posted.count == 3)
    await notifier.catchUp()
    #expect(await poster.posted.count == 3)
    // Whatever a banner says, never a word of what was spoken or answered.
    for banner in posted { #expect(!banner.title.contains("secret") && !banner.body.contains("secret")) }
    #expect(posted.first { $0.memoID == "b" }?.body == "Open Iris to choose a route.")
    #expect(posted.first { $0.memoID == "c" }?.body == "Open Iris to retry it.")
  }

  @Test("a catch-up does not repeat what an event already announced")
  func catchUpSeesWhatEventsSaid() async {
    let poster = RecordingNotificationPoster()
    let server = Server()
    server.memos = [memo("a", .acted)]
    let notifier = rig(poster, server)
    await notifier.catchUp()
    server.set("a", .notified)
    #expect(notifier.noteState(of: event("a", .notified)))
    await notifier.memoDone(id: "a")
    await notifier.catchUp()
    #expect(await poster.posted.map(\.memoID) == ["a"])
  }

  @Test("a memo this connection never saw is new only when it started after the baseline's newest")
  func unseenMemos() async {
    let poster = RecordingNotificationPoster()
    let server = Server()
    server.memos = [memo("old", .notified, minutesAgo: 30)]
    let notifier = rig(poster, server)
    await notifier.catchUp()
    server.memos.append(memo("new", .notified, minutesAgo: 1))
    server.memos.append(memo("older", .notified, minutesAgo: 90))
    await notifier.catchUp()
    #expect(await poster.posted.map(\.memoID) == ["new"])
  }

  @Test("an empty server's first memo is new")
  func emptyBaseline() async {
    let poster = RecordingNotificationPoster()
    let server = Server()
    let notifier = rig(poster, server)
    await notifier.catchUp()
    server.memos = [memo("a", .notified)]
    await notifier.catchUp()
    #expect(await poster.posted.map(\.memoID) == ["a"])
  }

  @Test("a long outage is not a wall of banners: the newest few are announced, the rest recorded")
  func catchUpIsBounded() async {
    let poster = RecordingNotificationPoster()
    let server = Server()
    server.memos = (0..<8).map { memo("m\($0)", .acted, minutesAgo: Double(20 - $0)) }
    let notifier = rig(poster, server)
    await notifier.catchUp()
    for index in 0..<8 { server.set("m\(index)", .notified) }
    await notifier.catchUp()
    #expect(await poster.posted.count == MemoNotifier.catchUpLimit)
    #expect(await poster.posted.map(\.memoID) == ["m7", "m6", "m5", "m4", "m3"])
    await notifier.catchUp()
    #expect(await poster.posted.count == MemoNotifier.catchUpLimit)
  }

  @Test("a memo that is running again after a retry is not announced by a catch-up, and is when it finishes")
  func retriedMemo() async {
    let poster = RecordingNotificationPoster()
    let server = Server()
    server.memos = [memo("a", .failed)]
    let notifier = rig(poster, server)
    await notifier.catchUp()
    server.set("a", .acted)
    await notifier.catchUp()
    server.set("a", .notified)
    await notifier.catchUp()
    #expect(await poster.posted.map(\.memoID) == ["a"])
  }

  @Test("a catch-up whose fetch comes back after a server switch records and posts nothing on the new server")
  func catchUpAcrossASwitch() async {
    let poster = RecordingNotificationPoster()
    let server = Server()
    server.memos = [memo("a", .acted)]
    let notifier = rig(poster, server)
    await notifier.catchUp()
    server.set("a", .notified)
    let (opened, open) = AsyncStream<Void>.makeStream()
    var started = false
    notifier.fetchRecent = {
      started = true
      for await _ in opened { break }
      return server.memos
    }
    let pending = Task { await notifier.catchUp() }
    #expect(await eventually { started })
    notifier.reset(connectionID: "c2")
    open.yield()
    open.finish()
    await pending.value
    #expect(await poster.posted.isEmpty && !notifier.hasBaseline)
  }

  @Test(
    "a banner the system takes while the connection switches is taken back, so it never names the old server's memo")
  func bannerDuringASwitch() async {
    let poster = RecordingNotificationPoster()
    await poster.holdPosts(true)
    let server = Server()
    server.memos = [memo("a", .notified)]
    let notifier = rig(poster, server)
    let pending = Task { await notifier.memoDone(id: "a") }
    #expect(await eventually { await poster.postsStarted == 1 })
    notifier.reset(connectionID: "c2")
    await poster.releasePost()
    await pending.value
    #expect(await poster.posted.map(\.connectionID) == ["c1"])
    #expect(await poster.delivered.isEmpty)
    // The id is free on the new server, and its banner carries the new connection.
    await poster.holdPosts(false)
    await notifier.memoDone(id: "a")
    #expect(await poster.delivered.map(\.connectionID) == ["c2"])
  }

  @Test("a server switch takes the old server's banners out of Notification Center")
  func switchWithdrawsBanners() async {
    let poster = RecordingNotificationPoster()
    let server = Server()
    server.memos = [memo("a", .notified)]
    let notifier = rig(poster, server)
    await notifier.memoDone(id: "a")
    #expect(await poster.delivered.count == 1)
    notifier.reset(connectionID: "c2")
    #expect(await eventually { await poster.delivered.isEmpty })
  }

  @Test("launch takes back banners left by another connection and keeps this one's")
  func launchWithdrawsForeignBanners() async throws {
    let poster = RecordingNotificationPoster()
    let server = Server()
    let notifier = rig(poster, server)
    try await poster.post(MemoNotification(memoID: "x", connectionID: "old", title: "t", body: "b"))
    try await poster.post(MemoNotification(memoID: "y", connectionID: "c1", title: "t", body: "b"))
    notifier.withdrawForeignBanners()
    #expect(await eventually { await poster.delivered.map(\.memoID) == ["y"] })
  }
}
