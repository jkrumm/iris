import IrisCore
import IrisUI
import SwiftUI

/// History · Stats · Settings. Threads are not a tab: a conversation is a History row (round 2).
struct RootView: View {
  let history: HistoryModel
  let stats: StatsModel
  let settings: SettingsModel
  let diagnostics: DiagnosticsModel
  var connectionForm: ConnectionModel?
  let makeDetail: (Memo) -> MemoDetailModel
  let makeComposer: (ComposerRequest) -> ComposerModel

  /// The tab shown first and the one the app jumps to when the connection is missing.
  enum Section: Hashable {
    case history, stats, settings
  }

  @State private var selection: Section

  init(
    history: HistoryModel, stats: StatsModel, settings: SettingsModel, diagnostics: DiagnosticsModel,
    connectionForm: ConnectionModel? = nil, startsOnSettings: Bool = false,
    makeDetail: @escaping (Memo) -> MemoDetailModel, makeComposer: @escaping (ComposerRequest) -> ComposerModel
  ) {
    self.history = history
    self.stats = stats
    self.settings = settings
    self.diagnostics = diagnostics
    self.connectionForm = connectionForm
    self.makeDetail = makeDetail
    self.makeComposer = makeComposer
    _selection = State(initialValue: startsOnSettings ? .settings : .history)
  }

  var body: some View {
    TabView(selection: $selection) {
      Tab(String(localized: "History", comment: "Tab title"), systemImage: "clock", value: Section.history) {
        HistoryView(model: history, makeDetail: makeDetail, makeComposer: makeComposer)
      }
      Tab(String(localized: "Stats", comment: "Tab title"), systemImage: "chart.bar", value: Section.stats) {
        StatsView(model: stats)
      }
      Tab(String(localized: "Settings", comment: "Tab title"), systemImage: "gearshape", value: Section.settings) {
        SettingsView(model: settings, history: history, diagnostics: diagnostics, connectionForm: connectionForm)
      }
    }
    .tint(Theme.Accent.tint)
  }
}
