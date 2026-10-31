import Foundation
import IrisCore
import Testing

@testable import IrisMac

/// Polls until `condition` holds, but never forever: a missing event fails the test after `seconds` instead of hanging the run.
@MainActor
func eventually(seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + .seconds(seconds)
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return await condition()
}

@MainActor
@Suite("Mac composition root")
struct MacCompositionRootTests {
  /// The sample Hermes memo that finished with a summary.
  private static let finished = "0b6d1f4e-3a52-4c1d-9f0e-7a2c5d8e1b34"

  private func fakeRoot(
    credentials: InMemoryCredentialStore = InMemoryCredentialStore(), poster: RecordingNotificationPoster? = nil,
    extra: [String] = []
  ) -> MacCompositionRoot {
    MacCompositionRoot(
      arguments: [MacCompositionRoot.fakeDataArgument] + extra, credentials: credentials,
      poster: poster ?? RecordingNotificationPoster())
  }

  @Test("the fake composition loads the sample memos from launch, with no Keychain")
  func loadsHistory() async {
    let root = fakeRoot()
    #expect(root.mode == .fake && root.isConfigured && root.page == .history)
    root.begin()
    #expect(await eventually { !root.history.memos.isEmpty })
    #expect(root.history.memos.contains { $0.id == Self.finished })
  }

  @Test("a memo.done event on the live stream posts a notification, with the panel closed")
  func notifiesOnDone() async {
    let poster = RecordingNotificationPoster()
    let root = fakeRoot(poster: poster)
    root.begin()
    #expect(await eventually { !root.history.memos.isEmpty })
    // The sample memo is finished already (the list's baseline); a run through the pipeline is a new transition.
    try? await root.fakeAPI?.advance(Self.finished, to: .acted)
    try? await root.fakeAPI?.advance(Self.finished, to: .notified)
    #expect(await eventually { await !poster.posted.isEmpty })
    #expect(await poster.posted.first?.memoID == Self.finished)
  }

  @Test("a memo that finished while the stream was down is announced when the stream is back, once")
  func catchesUpAfterTheStreamReturns() async throws {
    let poster = RecordingNotificationPoster()
    let root = fakeRoot(poster: poster)
    let fake = try #require(root.fakeAPI)
    root.begin()
    #expect(await eventually { !root.history.memos.isEmpty })
    // The memo is still running when the connection is first read (the baseline) ...
    var detail = try await fake.memo(id: Self.finished)
    detail.memo.state = .acted
    await fake.seed(detail)
    fake.emit(.ready)
    #expect(await eventually { root.notifier.hasBaseline })
    #expect(await poster.posted.isEmpty)
    // ... and has finished by the time the stream says `ready` again, with no event in between.
    detail.memo.state = .notified
    await fake.seed(detail)
    fake.emit(.ready)
    #expect(await eventually { await poster.posted.map(\.memoID) == [Self.finished] })
    fake.emit(.ready)
    try? await Task.sleep(for: .milliseconds(300))
    #expect(await poster.posted.count == 1)
  }

  @Test("the catch-up reads the newest memos with no filter, whatever History is showing")
  func catchUpIsUnfiltered() async throws {
    let root = fakeRoot()
    root.begin()
    #expect(await eventually { !root.history.memos.isEmpty })
    root.history.filters.searchText = "no memo says this"
    let recent = try #require(await root.notifier.fetchRecent())
    #expect(recent.contains { $0.id == Self.finished })
  }

  @Test("opening a memo selects it for the detail panel and asks the app to open the window")
  func opensDetail() {
    let root = fakeRoot()
    let before = root.detailRequest
    root.openDetail("a")
    root.openDetail("b")
    #expect(root.detailMemoID == "b" && root.detailRequest == before + 2)
  }

  @Test("-IrisMacSettings opens the panel on Settings")
  func settingsPage() {
    #expect(fakeRoot(extra: [MacCompositionRoot.settingsArgument]).page == .settings)
  }

  @Test("production with nothing saved opens on Settings and counts as not configured")
  func notConfigured() {
    let root = MacCompositionRoot(arguments: [], credentials: InMemoryCredentialStore())
    #expect(root.mode == .production && !root.isConfigured && root.page == .settings)
  }

  @Test("production with a saved connection opens on History")
  func configured() throws {
    let store = InMemoryCredentialStore()
    try store.save(try #require(ConnectionCredentials(urlText: "https://iris.example.com", token: "t")))
    let root = MacCompositionRoot(arguments: [], credentials: store)
    #expect(root.isConfigured && root.page == .history)
  }

  @Test("saving the connection stores it, bumps the revision and moves the panel to History")
  func saving() {
    let store = InMemoryCredentialStore()
    let root = fakeRoot(credentials: store, extra: [MacCompositionRoot.settingsArgument])
    root.connectionForm.urlText = "https://iris.example.com"
    root.connectionForm.tokenText = "token"
    root.connectionForm.save()
    #expect(store.load()?.token == "token" && root.connectionRevision == 1)
    #expect(root.isConfigured && root.page == .history)
    root.connectionForm.urlText = "http://iris.example.com"
    root.connectionForm.save()
    #expect(root.connectionForm.failure == .insecure && root.connectionRevision == 1)
  }

  @Test("an unanswered notification prompt holds neither History nor the event stream back; memos wait for the answer")
  func promptDoesNotBlockHistory() async {
    let poster = RecordingNotificationPoster(permission: .undetermined, holdsPrompt: true)
    let root = fakeRoot(poster: poster)
    root.begin()
    #expect(await eventually { !root.history.memos.isEmpty && root.history.link == .live })
    #expect(await eventually { await poster.requests == 1 })
    root.fakeAPI?.emit(.memoUpdated(MemoEvent(id: Self.finished, state: .notified, at: .now)))
    root.fakeAPI?.emit(.memoDone(MemoEvent(id: Self.finished, state: .notified, at: .now)))
    #expect(await eventually { root.history.revision(of: Self.finished) > 0 })
    #expect(await poster.posted.isEmpty)
    await poster.answerPrompt(true)
    #expect(await eventually { await poster.posted.map(\.memoID) == [Self.finished] })
  }

  @Test("an open detail reloads when the stream says ready, not when a list request succeeds during an outage")
  func reconnectsCountStreamReady() async {
    let root = fakeRoot()
    root.begin()
    #expect(await eventually { root.history.link == .live })
    let before = root.reconnects
    await root.history.load()
    #expect(root.reconnects == before)
    root.fakeAPI?.emit(.ready)
    #expect(await eventually { root.reconnects > before })
  }

  @Test("a banner click opens the memo, unless the banner is of another connection")
  func clicksAreBoundToTheirConnection() {
    let root = fakeRoot()
    let banner = root.notifier.connectionID
    root.openFromNotification(Self.finished, connection: banner)
    #expect(root.detailMemoID == Self.finished)

    root.openFromNotification("other", connection: banner)
    switchServer(root)
    #expect(root.detailMemoID == nil)
    root.openFromNotification(Self.finished, connection: banner)
    #expect(root.detailMemoID == nil)
    root.openFromNotification(Self.finished, connection: root.notifier.connectionID)
    #expect(root.detailMemoID == Self.finished)
  }

  private func savedConnection(_ url: String, _ token: String) throws -> InMemoryCredentialStore {
    let store = InMemoryCredentialStore()
    try store.save(try #require(ConnectionCredentials(urlText: url, token: token)))
    return store
  }

  @Test(
    "a banner from before a restart still opens its memo; the connection id changes only with the server URL or the token"
  )
  func connectionIDSurvivesRestart() throws {
    let before = MacCompositionRoot(arguments: [], credentials: try savedConnection("https://iris.example.com", "t1"))
    let banner = before.notifier.connectionID

    let restarted = MacCompositionRoot(
      arguments: [], credentials: try savedConnection("https://iris.example.com", "t1"))
    #expect(restarted.notifier.connectionID == banner)
    restarted.openFromNotification(Self.finished, connection: banner)
    #expect(restarted.detailMemoID == Self.finished)

    let otherToken = MacCompositionRoot(
      arguments: [], credentials: try savedConnection("https://iris.example.com", "t2"))
    let otherServer = MacCompositionRoot(
      arguments: [], credentials: try savedConnection("https://other.example.com", "t1"))
    #expect(otherToken.notifier.connectionID != banner && otherServer.notifier.connectionID != banner)
    otherServer.openFromNotification(Self.finished, connection: banner)
    #expect(otherServer.detailMemoID == nil)
    #expect(!banner.contains("t1") && !banner.contains("iris"))
  }

  @Test("saving the same connection again keeps the banners valid; saving another one invalidates them")
  func savingKeepsOrRotatesTheID() throws {
    let root = fakeRoot()
    root.connectionForm.urlText = "https://iris.example.com"
    root.connectionForm.tokenText = "t1"
    root.connectionForm.save()
    let saved = root.notifier.connectionID
    root.connectionForm.save()
    #expect(root.notifier.connectionID == saved)
    root.connectionForm.tokenText = "t2"
    root.connectionForm.save()
    #expect(root.notifier.connectionID != saved)
  }

  @Test("the event stream runs while the first list request is still unanswered")
  func streamDoesNotWaitForTheList() async throws {
    let poster = RecordingNotificationPoster()
    let root = fakeRoot(poster: poster)
    let fake = try #require(root.fakeAPI)
    let gate = await fake.hold(.listMemos)
    root.begin()
    await gate.waitUntilHeld()
    #expect(root.history.memos.isEmpty)

    fake.emit(.ready)
    fake.emit(.memoDone(MemoEvent(id: Self.finished, state: .notified, at: .now)))
    #expect(await eventually { !root.history.memos.isEmpty })
    #expect(await eventually { await poster.posted.map(\.memoID) == [Self.finished] })
    gate.release()
  }

  @Test("two taps on one memo reach the server in order, each on the memo as it is then: the last tap wins")
  func actionsOnOneMemoAreSerialized() async throws {
    let root = fakeRoot()
    let fake = try #require(root.fakeAPI)
    root.begin()
    #expect(await eventually { !root.history.memos.isEmpty })
    let id = Self.finished
    let initial = try #require(root.history.memos.first { $0.id == id }).favorite
    let gate = await fake.hold(.setFlags)

    func tap() {
      root.perform(on: root.history, memoID: id) { model in
        guard let current = model.memos.first(where: { $0.id == id }) else { return }
        await model.toggleFavorite(current)
      }
    }
    tap()
    await gate.waitUntilHeld()
    tap()
    try? await Task.sleep(for: .milliseconds(150))
    let during = await fake.calls.filter { if case .setFlags = $0 { true } else { false } }.count
    #expect(during == 1, "the second tap went out while the first was still on the wire")

    gate.release()
    #expect(
      await eventually {
        await fake.calls.filter { if case .setFlags = $0 { true } else { false } }.count == 2
      })
    #expect(await eventually { await fake.memos[id]?.memo.favorite == initial })
  }

  @Test("a connection change replaces the list, closes the detail and forgets what was announced")
  func switchingServers() async {
    let poster = RecordingNotificationPoster()
    let root = fakeRoot(poster: poster)
    root.begin()
    #expect(await eventually { !root.history.memos.isEmpty })
    let before = root.history
    root.openDetail(Self.finished)
    let dismissals = root.detailDismissals

    root.connectionForm.urlText = "https://other.example.com"
    root.connectionForm.tokenText = "token"
    root.connectionForm.save()
    #expect(root.history !== before)
    #expect(root.detailMemoID == nil && root.detailDismissals == dismissals + 1)
    #expect(root.history.onMemoDone != nil)
    #expect(await eventually { !root.history.memos.isEmpty })
  }

  private func switchServer(_ root: MacCompositionRoot) {
    root.connectionForm.urlText = "https://other.example.com"
    root.connectionForm.tokenText = "token"
    root.connectionForm.save()
  }

  @Test("a row action runs on the model it was made for, and is dropped when the connection changed first")
  func queuedActionsAreBoundToTheirConnection() async {
    let root = fakeRoot()
    root.begin()
    #expect(await eventually { !root.history.memos.isEmpty })
    var ran: [String] = []
    root.perform(on: root.history) { _ in ran.append("current") }
    #expect(await eventually { ran == ["current"] })

    let old = root.history
    root.perform(on: old) { _ in ran.append("old") }
    switchServer(root)
    root.perform(on: old) { _ in ran.append("old again") }
    try? await Task.sleep(for: .milliseconds(200))
    #expect(ran == ["current"])
  }

  @Test("a memo.done seen before a switch posts nothing once its task runs after it")
  func staleEventsAreDropped() async {
    let poster = RecordingNotificationPoster()
    let root = fakeRoot(poster: poster)
    root.begin()
    #expect(await eventually { !root.history.memos.isEmpty })
    root.history.onMemoDone?(Self.finished)
    switchServer(root)
    try? await Task.sleep(for: .milliseconds(300))
    #expect(await poster.posted.isEmpty)
  }
}

@Suite("Mac connection status")
struct MacConnectionStatusTests {
  @Test("the line follows the app's own traffic, and never says Connected for a server it cannot reach")
  func tones() {
    #expect(MacConnectionStatus(isConfigured: false, link: .live).tone == .warn)
    #expect(MacConnectionStatus(isConfigured: true, link: .live) == .init(isConfigured: true, link: .live))
    #expect(MacConnectionStatus(isConfigured: true, link: .live).tone == .good)
    #expect(MacConnectionStatus(isConfigured: true, link: .unreachable).tone == .bad)
    #expect(MacConnectionStatus(isConfigured: true, link: .unreachable).hint != nil)
    #expect(MacConnectionStatus(isConfigured: true, link: .rejected).tone == .bad)
    #expect(MacConnectionStatus(isConfigured: true, link: .unknown).tone == .muted)
  }
}
