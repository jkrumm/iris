import IrisCore
import IrisUI
import SwiftUI

/// History · Stats · Settings. Threads are not a tab: a conversation is a History row (round 2).
struct RootView: View {
  let history: HistoryModel
  /// A server URL and token are saved; without them History shows a prompt that opens Settings → Connection.
  let isConfigured: Bool
  @Bindable var take: TakeModel
  let stats: StatsModel
  let settings: SettingsModel
  let diagnostics: DiagnosticsModel
  let micRules: MicRulesModel
  let spokenReplies: SpokenReplies
  var connectionForm: ConnectionModel?
  let makeDetail: (Memo) -> MemoDetailModel
  let makeComposer: (ComposerRequest) -> ComposerModel
  let makeThread: (Memo) -> ThreadModel
  let router: ConversationRouter
  let presence: ConversationPresence
  /// Reads a memo History's list does not hold (a link on a cold launch).
  let fetchMemo: (String) async throws -> Memo

  /// The tab shown first and the one the app jumps to when the connection is missing.
  enum Section: Hashable {
    case history, stats, settings
  }

  @State private var selection: Section
  /// Screens with their own bottom actions (a memo's detail, a thread) take the record control off the screen while shown.
  @State private var accessoryPresence = RecordAccessoryPresence()
  /// The composer the record row's Text button opens.
  @State private var composer: ComposerRequest?
  /// The screens pushed on History's stack.
  @State private var historyPath: [Memo] = []

  init(
    history: HistoryModel, isConfigured: Bool = true, take: TakeModel, stats: StatsModel,
    settings: SettingsModel,
    diagnostics: DiagnosticsModel, micRules: MicRulesModel, spokenReplies: SpokenReplies,
    connectionForm: ConnectionModel? = nil, startsOnSettings: Bool = false,
    makeDetail: @escaping (Memo) -> MemoDetailModel, makeComposer: @escaping (ComposerRequest) -> ComposerModel,
    makeThread: @escaping (Memo) -> ThreadModel, router: ConversationRouter, presence: ConversationPresence,
    fetchMemo: @escaping (String) async throws -> Memo
  ) {
    self.history = history
    self.isConfigured = isConfigured
    self.take = take
    self.stats = stats
    self.settings = settings
    self.diagnostics = diagnostics
    self.micRules = micRules
    self.spokenReplies = spokenReplies
    self.connectionForm = connectionForm
    self.makeDetail = makeDetail
    self.makeComposer = makeComposer
    self.makeThread = makeThread
    self.router = router
    self.presence = presence
    self.fetchMemo = fetchMemo
    _selection = State(initialValue: startsOnSettings ? .settings : .history)
  }

  var body: some View {
    TabView(selection: $selection) {
      Tab(String(localized: "History", comment: "Tab title"), systemImage: "clock", value: Section.history) {
        HistoryView(
          model: history, path: $historyPath, isConfigured: isConfigured, onConnect: { selection = .settings },
          makeDetail: makeDetail,
          makeComposer: makeComposer, makeThread: makeThread)
      }
      Tab(String(localized: "Stats", comment: "Tab title"), systemImage: "chart.bar", value: Section.stats) {
        StatsView(model: stats)
      }
      Tab(String(localized: "Settings", comment: "Tab title"), systemImage: "gearshape", value: Section.settings) {
        SettingsView(
          model: settings, history: history, diagnostics: diagnostics, micRules: micRules,
          spokenReplies: spokenReplies, connectionForm: connectionForm)
      }
    }
    .tint(Theme.Accent.tint)
    // The record control sits above the tab bar on every screen; a running take replaces it (the banner below).
    .modifier(
      RecordRowModifier(model: take, isCovered: accessoryPresence.isHidden, onCompose: { composer = ComposerRequest() })
    )
    .sheet(item: $composer) { request in
      BuiltOnce(make: { makeComposer(request) }) { composer in
        ComposerView(model: composer, onSent: { history.insert($0) }, onQueued: { history.didQueue() })
      }
      .id(request.id)
    }
    .environment(accessoryPresence)
    .environment(router)
    .environment(presence)
    // A take continues as a compact banner under each screen's navigation bar (`takeBanner()`); tapping it brings the
    // take screen back.
    .environment(take)
    .fullScreenCover(isPresented: $take.showsFull) {
      TakeView(model: take)
    }
    .alert(
      String(localized: "Recording", comment: "Take failure alert title"),
      isPresented: Binding(get: { take.failure != nil }, set: { if !$0 { take.failure = nil } })
    ) {
      Button(String(localized: "OK", comment: "Dismisses the take failure alert"), role: .cancel) {}
    } message: {
      Text(verbatim: take.failure ?? "")
    }
    .task { await take.run() }
    // A link, a notification or the Live Activity wants a conversation. A running take is left alone; the composer sheet goes.
    .task(id: router.pending?.id) { await openPendingConversation() }
    .onChange(of: visibleScreen, initial: true) { previous, screen in
      if previous != screen {
        DeviceLog.shared.event("ui.screen", ["screen": .string(previous), "shown": false])
      }
      DeviceLog.shared.event("ui.screen", ["screen": .string(screen), "shown": true])
    }
  }

  /// Resolves the router's pending request and pushes the conversation (or the detail of a memo that is not one) on History.
  private func openPendingConversation() async {
    guard let request = router.pending else { return }
    let opened = await router.resolve(
      request, isConfigured: isConfigured, local: { id in history.memos.first { $0.id == id } }, fetch: fetchMemo)
    guard let opened else { return }
    composer = nil
    selection = .history
    historyPath = [opened.memo]
  }

  /// What the owner is looking at, for `ui.screen`: the take screen over the selected tab.
  private var visibleScreen: String {
    if take.showsFull { return "take" }
    return switch selection {
    case .history: "history"
    case .stats: "stats"
    case .settings: "settings"
    }
  }
}

/// The record row (Hermes, Transcribe, Text) as the tab bar's bottom accessory. `isEnabled` (iOS 26.1) hides it while a take runs and while a screen
/// with its own bottom actions is shown (`isCovered`: hiding the tab bar does not hide the accessory, and it would sit over those
/// actions); on 26.0 it stays and is disabled while a take runs, since `canStart` is false then.
private struct RecordRowModifier: ViewModifier {
  let model: TakeModel
  let isCovered: Bool
  let onCompose: () -> Void

  func body(content: Content) -> some View {
    if #available(iOS 26.1, *) {
      content.tabViewBottomAccessory(isEnabled: !model.isActive && !isCovered) {
        RecordRow(model: model, onCompose: onCompose)
      }
    } else {
      content.tabViewBottomAccessory { RecordRow(model: model, onCompose: onCompose) }
    }
  }
}
