import Foundation
import IrisCore
import Synchronization
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
    #expect(root.mode == .fake && root.isConfigured && !root.needsOnboarding)
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

  @Test("a popover click selects the memo for the main window and asks the app to open it")
  func opensWindow() {
    let root = fakeRoot()
    let before = root.windowRequest
    root.show("a")
    root.show("b")
    #expect(root.selectedMemoID == "b" && root.windowRequest == before + 2)
  }

  @Test("Open Iris opens the window as it is, without changing the selection")
  func opensWindowAsIs() {
    let root = fakeRoot()
    root.show("a")
    let before = root.windowRequest
    root.showMainWindow()
    #expect(root.selectedMemoID == "a" && root.windowRequest == before + 1)
  }

  @Test("the window's list is its own: a sidebar scope narrows it and leaves the popover's list unfiltered")
  func windowListIsSeparate() async {
    let root = fakeRoot()
    root.begin()
    #expect(await eventually { !root.history.memos.isEmpty })
    #expect(root.windowHistory !== root.history)
    root.scope = .favorites
    #expect(root.windowHistory.filters.quick == .favorites)
    #expect(root.history.filters == HistoryFilters())
    root.windowHistory.filters.searchText = "journal"
    root.scope = .threads
    #expect(root.windowHistory.filters.query().thread && root.windowHistory.filters.quick == nil)
    #expect(root.windowHistory.filters.searchText == "journal", "a scope change keeps the search")
    root.scope = nil
    #expect(root.scope == .threads, "a deselect keeps the scope")
    root.scope = .all
    #expect(root.windowHistory.filters.quick == nil && !root.windowHistory.filters.query().thread)
  }

  /// The window's list loads from its own view; a test loads it (the sample memos are seeded by `begin()`, so the first loads may be empty).
  private func loadedWindow(_ root: MacCompositionRoot) async -> Bool {
    await eventually {
      await root.windowHistory.load()
      return !root.windowHistory.memos.isEmpty
    }
  }

  @Test("actions from the main window's list run, and are dropped after a connection change")
  func windowActionsRun() async {
    let root = fakeRoot()
    let fake = root.fakeAPI
    root.begin()
    #expect(await loadedWindow(root))
    let ran = Mutex(0)
    root.perform(on: root.windowHistory) { _ in ran.withLock { $0 += 1 } }
    #expect(await eventually { ran.withLock { $0 } == 1 })

    let stale = root.windowHistory
    let old = root.history
    switchServer(root)
    root.perform(on: stale) { _ in ran.withLock { $0 += 1 } }
    root.perform(on: old) { _ in ran.withLock { $0 += 1 } }
    try? await Task.sleep(for: .milliseconds(200))
    #expect(ran.withLock { $0 } == 1, "an action of the old connection never runs")
    _ = fake
  }

  @Test(
    "a memo opened from outside becomes held by the window list, and its actions then run: two toggles toggle twice")
  func openedMemoBecomesHeld() async throws {
    let root = fakeRoot()
    let fake = try #require(root.fakeAPI)
    root.begin()
    #expect(await loadedWindow(root))
    root.scope = .favorites
    root.windowHistory.filters.searchText = "nothing says this"
    #expect(await eventually { !root.windowHistory.isLoading })
    await root.windowHistory.load()
    let memo = try await fake.memo(id: Self.finished).memo
    #expect(!root.windowHistory.memos.contains { $0.id == memo.id })

    await root.ensureHeld(memo)
    #expect(root.scope == .all && root.windowHistory.filters.searchText.isEmpty)
    #expect(root.windowHistory.memos.contains { $0.id == memo.id })

    let initial = memo.favorite
    let actions = MacMemoActions(root: root, model: root.windowHistory)
    actions.toggleFavorite(memo)
    actions.toggleFavorite(memo)
    #expect(
      await eventually { await fake.calls.filter { if case .setFlags = $0 { true } else { false } }.count == 2 })
    #expect(await eventually { await fake.memos[Self.finished]?.memo.favorite == initial })
  }

  @Test("Delete clears the selection at the tap, is off while queued, runs once, and frees the memo when done")
  func deleteIsQueuedOnce() async throws {
    let root = fakeRoot()
    let fake = try #require(root.fakeAPI)
    root.begin()
    #expect(await loadedWindow(root))
    let memo = try await fake.memo(id: Self.finished).memo
    let gate = await fake.hold(.deleteMemo)
    root.show(memo.id)
    let actions = MacMemoActions(root: root, model: root.windowHistory)

    actions.delete(memo)
    #expect(root.selectedMemoID == nil && root.deletingIDs == [memo.id], "cleared and marked at the tap")
    actions.delete(memo)
    await gate.waitUntilHeld()
    gate.release()
    #expect(await eventually { await fake.memos[Self.finished]?.memo.deletedAt != nil })
    #expect(await eventually { root.deletingIDs.isEmpty })
    #expect(await fake.calls.filter { if case .deleteMemo = $0 { true } else { false } }.count == 1)
  }

  @Test("Delete on a memo that cannot be deleted keeps the selection")
  func undeletableKeepsSelection() async throws {
    let root = fakeRoot()
    let fake = try #require(root.fakeAPI)
    root.begin()
    #expect(await loadedWindow(root))
    var memo = try await fake.memo(id: Self.finished).memo
    memo.state = .received
    root.show(memo.id)
    MacMemoActions(root: root, model: root.windowHistory).delete(memo)
    #expect(root.selectedMemoID == memo.id && root.deletingIDs.isEmpty)
  }

  @Test("the detail model is one per memo until another is asked for or the connection changes")
  func modelsAreCached() throws {
    let root = fakeRoot()
    let first = root.detailModel(for: "a")
    #expect(root.detailModel(for: "a") === first && root.detailModel(for: "b") !== first)
    let before = root.detailModel(for: "a")
    switchServer(root)
    #expect(root.detailModel(for: "a") !== before)
  }

  @Test("the sidebar scopes map onto the shared filters: All, Favorites, Archive and Threads")
  func scopesMapOntoFilters() {
    var filters = HistoryFilters()
    MacLibraryScope.all.apply(to: &filters)
    #expect(filters.query() == HistoryFilters().query() && !filters.isFiltering)
    MacLibraryScope.favorites.apply(to: &filters)
    #expect(filters.query().favorite && !filters.query().archived && !filters.query().thread)
    MacLibraryScope.archive.apply(to: &filters)
    #expect(filters.query().archived && !filters.query().favorite)
    MacLibraryScope.threads.apply(to: &filters)
    #expect(filters.query().thread && !filters.query().archived && filters.needsServerMatching)
    MacLibraryScope.all.apply(to: &filters)
    #expect(!filters.query().thread && !filters.isFiltering, "the next scope drops the previous narrowing")
  }

  @Test("the popover's Hermes and Transcribe buttons start a take in their own mode; the hotkey starts Hermes")
  func popoverPairStartsItsMode() async throws {
    let root = fakeRoot()
    let engine = try #require(root.fakeTake)
    root.recording.toggle(mode: .transcribe)
    await root.recording.settled()
    #expect(root.recording.isRecording && engine.startedModes == [.transcribe])
    root.recording.stop()
    await root.recording.settled()
    root.recording.toggle(mode: .hermes)
    await root.recording.settled()
    root.recording.stop()
    await root.recording.settled()
    root.recording.toggle()
    await root.recording.settled()
    #expect(engine.startedModes == [.transcribe, .hermes, .hermes])
    root.recording.cancel()
    await root.recording.settled()
  }

  @Test("the window list loads its first page and finds the sample memos")
  func windowListLoads() async {
    let root = fakeRoot()
    root.begin()
    root.windowDidAppear()
    // The sample memos are seeded by `begin()`, so the first loads may be empty.
    #expect(
      await eventually {
        await root.windowHistory.load()
        return root.windowHistory.memos.contains { $0.id == Self.finished }
      })
    root.windowDidDisappear()
  }

  @Test("onboarding is for a real install with nothing saved; a saved connection and the fake composition skip it")
  func onboardingGate() throws {
    #expect(MacCompositionRoot(arguments: [], credentials: InMemoryCredentialStore()).needsOnboarding)
    #expect(
      !MacCompositionRoot(arguments: [], credentials: try savedConnection("https://iris.example.com", "t"))
        .needsOnboarding)
    #expect(!fakeRoot().needsOnboarding)
  }

  @Test("the onboarding, Settings and main window requests each count once")
  func windowRequests() {
    let root = fakeRoot()
    root.showOnboarding()
    root.showSettings()
    #expect(root.onboardingRequest == 1 && root.settingsRequest == 1 && root.windowRequest == 0)
  }

  @Test("saving from onboarding stores the connection, then the main window can open")
  func onboardingSaves() {
    let store = InMemoryCredentialStore()
    let root = MacCompositionRoot(arguments: [], credentials: store)
    #expect(root.needsOnboarding)
    root.connectionForm.urlText = "https://iris.example.com"
    root.connectionForm.tokenText = "token"
    root.connectionForm.save()
    #expect(store.load()?.token == "token" && !root.needsOnboarding)
    root.showMainWindow(source: "onboarding")
    #expect(root.windowRequest == 1)
  }

  @Test("production with nothing saved counts as not configured")
  func notConfigured() {
    let root = MacCompositionRoot(arguments: [], credentials: InMemoryCredentialStore())
    #expect(root.mode == .production && !root.isConfigured)
  }

  @Test("production with a saved connection is configured")
  func configured() throws {
    let store = InMemoryCredentialStore()
    try store.save(try #require(ConnectionCredentials(urlText: "https://iris.example.com", token: "t")))
    let root = MacCompositionRoot(arguments: [], credentials: store)
    #expect(root.isConfigured)
  }

  @Test("saving the connection stores it and bumps the revision")
  func saving() {
    let store = InMemoryCredentialStore()
    let root = fakeRoot(credentials: store)
    root.connectionForm.urlText = "https://iris.example.com"
    root.connectionForm.tokenText = "token"
    root.connectionForm.save()
    #expect(store.load()?.token == "token" && root.connectionRevision == 1)
    #expect(root.isConfigured)
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
    #expect(root.selectedMemoID == Self.finished)

    root.openFromNotification("other", connection: banner)
    switchServer(root)
    #expect(root.selectedMemoID == nil)
    root.openFromNotification(Self.finished, connection: banner)
    #expect(root.selectedMemoID == nil)
    root.openFromNotification(Self.finished, connection: root.notifier.connectionID)
    #expect(root.selectedMemoID == Self.finished)
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
    #expect(restarted.selectedMemoID == Self.finished)

    let otherToken = MacCompositionRoot(
      arguments: [], credentials: try savedConnection("https://iris.example.com", "t2"))
    let otherServer = MacCompositionRoot(
      arguments: [], credentials: try savedConnection("https://other.example.com", "t1"))
    #expect(otherToken.notifier.connectionID != banner && otherServer.notifier.connectionID != banner)
    otherServer.openFromNotification(Self.finished, connection: banner)
    #expect(otherServer.selectedMemoID == nil)
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

    // `ready` reloads the list and starts the notifier's baseline catch-up, though the first list request is still out. The
    // baseline records what is finished already; a memo's finish is announced only as a transition after it, so wait for it
    // (the two race otherwise: a `memo.done` noted before the baseline fetch lands is announced, one after it is not).
    fake.emit(.ready)
    #expect(await eventually { !root.history.memos.isEmpty })
    #expect(await eventually { root.notifier.hasBaseline })
    try await fake.advance(Self.finished, to: .acted)
    try await fake.advance(Self.finished, to: .notified)
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

  @Test("a connection change replaces both lists, clears the selection and forgets what was announced")
  func switchingServers() async {
    let poster = RecordingNotificationPoster()
    let root = fakeRoot(poster: poster)
    root.begin()
    #expect(await eventually { !root.history.memos.isEmpty })
    let before = root.history
    let windowBefore = root.windowHistory
    root.show(Self.finished)

    root.connectionForm.urlText = "https://other.example.com"
    root.connectionForm.tokenText = "token"
    root.connectionForm.save()
    #expect(root.history !== before && root.windowHistory !== windowBefore)
    #expect(root.selectedMemoID == nil)
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

  @Test("a memo.done on the stream announces the memo once, with no memo.updated and no History hook")
  func memoDoneOnTheStreamPosts() async throws {
    let poster = RecordingNotificationPoster()
    let root = fakeRoot(poster: poster)
    let fake = try #require(root.fakeAPI)
    root.begin()
    #expect(await eventually { !root.history.memos.isEmpty })
    var detail = try await fake.memo(id: Self.finished)
    detail.memo.state = .acted
    await fake.seed(detail)
    fake.emit(.memoUpdated(MemoEvent(id: Self.finished, state: .acted, at: .now)))
    detail.memo.state = .notified
    await fake.seed(detail)
    let done = MemoEvent(id: Self.finished, state: .notified, at: .now)
    fake.emit(.memoDone(done))
    #expect(await eventually { await poster.posted.map(\.memoID) == [Self.finished] })
    fake.emit(.memoDone(done))
    try? await Task.sleep(for: .milliseconds(300))
    #expect(await poster.posted.count == 1)
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

@MainActor
@Suite("Mac server binding")
struct MacServerBindingTests {
  private func credentials(_ url: String) throws -> ConnectionCredentials {
    try #require(ConnectionCredentials(urlText: url, token: "t"))
  }

  private func fakeRoot() -> MacCompositionRoot {
    MacCompositionRoot(
      arguments: [MacCompositionRoot.fakeDataArgument], credentials: InMemoryCredentialStore(),
      poster: RecordingNotificationPoster())
  }

  private func switchServer(_ root: MacCompositionRoot, to url: String) {
    root.connectionForm.urlText = url
    root.connectionForm.tokenText = "token"
    root.connectionForm.save()
  }

  @Test("the capture stack's server key follows the saved connection, and is nil without one")
  func stackServerKey() throws {
    let a = try credentials("https://a.example.com")
    let b = try credentials("https://b.example.com")
    let root = FileManager.default.temporaryDirectory.appending(path: "iris-mac-bind-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let log = MacTelemetry.makeDeviceLog(fake: true, credentials: InMemoryCredentialStore())
    let stack = MacCaptureStack.production(credentials: a, log: log, root: root)
    #expect(stack.serverKey == a.serverKey)
    stack.reconnect(b)
    #expect(stack.serverKey == b.serverKey && b.serverKey != a.serverKey)
    stack.reconnect(nil)
    #expect(stack.serverKey == nil)
  }

  @Test("a History load that is still out when the connection changes is dropped: the old server's list never shows")
  func staleListAfterASwitch() async throws {
    let root = fakeRoot()
    let fake = try #require(root.fakeAPI)
    await SampleData.seed(fake)
    let old = root.history
    let gate = await fake.hold(.listMemos)
    let loading = Task { await old.load() }
    await gate.waitUntilHeld()
    switchServer(root, to: "https://other.example.com")
    #expect(root.history !== old)
    gate.release()
    await loading.value
    #expect(old.memos.isEmpty && !old.hasLoaded)
  }

  @Test("a memo created on another server than the one History reads is not inserted; one with no origin is")
  func insertByOrigin() async throws {
    let root = fakeRoot()
    switchServer(root, to: "https://other.example.com")
    let current = try credentials("https://other.example.com").serverKey
    let memo = Memo(
      id: "11111111-2222-4333-8444-555555555555", mode: .hermes, device: "mac", startedAt: .now, state: .received,
      createdAt: .now, updatedAt: .now)
    root.history.insert(memo, origin: "some-other-server")
    #expect(root.history.memos.isEmpty)
    root.history.insert(memo, origin: current)
    #expect(root.history.memos.map(\.id) == [memo.id])
  }
}
