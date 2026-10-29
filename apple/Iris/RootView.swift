import IrisCore
import IrisUI
import SwiftUI

/// History · Stats · Settings. Threads are not a tab: a conversation is a History row (round 2).
struct RootView: View {
  let history: HistoryModel
  @Bindable var take: TakeModel
  let stats: StatsModel
  let settings: SettingsModel
  let diagnostics: DiagnosticsModel
  var connectionForm: ConnectionModel?
  let makeDetail: (Memo) -> MemoDetailModel
  let makeComposer: (ComposerRequest) -> ComposerModel
  let makeThread: (ThreadRoute) -> ThreadModel

  /// The tab shown first and the one the app jumps to when the connection is missing.
  enum Section: Hashable {
    case history, stats, settings
  }

  @State private var selection: Section

  init(
    history: HistoryModel, take: TakeModel, stats: StatsModel, settings: SettingsModel, diagnostics: DiagnosticsModel,
    connectionForm: ConnectionModel? = nil, startsOnSettings: Bool = false,
    makeDetail: @escaping (Memo) -> MemoDetailModel, makeComposer: @escaping (ComposerRequest) -> ComposerModel,
    makeThread: @escaping (ThreadRoute) -> ThreadModel
  ) {
    self.history = history
    self.take = take
    self.stats = stats
    self.settings = settings
    self.diagnostics = diagnostics
    self.connectionForm = connectionForm
    self.makeDetail = makeDetail
    self.makeComposer = makeComposer
    self.makeThread = makeThread
    _selection = State(initialValue: startsOnSettings ? .settings : .history)
  }

  var body: some View {
    TabView(selection: $selection) {
      Tab(String(localized: "History", comment: "Tab title"), systemImage: "clock", value: Section.history) {
        HistoryView(model: history, makeDetail: makeDetail, makeComposer: makeComposer, makeThread: makeThread)
      }
      Tab(String(localized: "Stats", comment: "Tab title"), systemImage: "chart.bar", value: Section.stats) {
        StatsView(model: stats)
      }
      Tab(String(localized: "Settings", comment: "Tab title"), systemImage: "gearshape", value: Section.settings) {
        SettingsView(model: settings, history: history, diagnostics: diagnostics, connectionForm: connectionForm)
      }
    }
    .tint(Theme.Accent.tint)
    // The record control sits above the tab bar on every screen; a running take replaces it (the banner below).
    .modifier(RecordAccessoryModifier(model: take))
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
  }
}

/// The record control as the tab bar's bottom accessory. `isEnabled` (iOS 26.1) hides it while a take runs; on 26.0 it stays
/// and is disabled, since `canStart` is false then.
private struct RecordAccessoryModifier: ViewModifier {
  let model: TakeModel

  func body(content: Content) -> some View {
    if #available(iOS 26.1, *) {
      content.tabViewBottomAccessory(isEnabled: !model.isActive) { RecordAccessory(model: model) }
    } else {
      content.tabViewBottomAccessory { RecordAccessory(model: model) }
    }
  }
}
