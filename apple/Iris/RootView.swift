import IrisCore
import IrisUI
import SwiftUI

/// History · Stats · Settings. Threads are not a tab: a conversation is a History row (round 2).
struct RootView: View {
  let history: HistoryModel
  let stats: StatsModel
  let settings: SettingsModel
  let diagnostics: DiagnosticsModel
  let makeDetail: (Memo) -> MemoDetailModel
  let makeComposer: (ComposerRequest) -> ComposerModel

  var body: some View {
    TabView {
      Tab(String(localized: "History", comment: "Tab title"), systemImage: "clock") {
        HistoryView(model: history, makeDetail: makeDetail, makeComposer: makeComposer)
      }
      Tab(String(localized: "Stats", comment: "Tab title"), systemImage: "chart.bar") {
        StatsView(model: stats)
      }
      Tab(String(localized: "Settings", comment: "Tab title"), systemImage: "gearshape") {
        SettingsView(model: settings, history: history, diagnostics: diagnostics)
      }
    }
    .tint(Theme.Accent.tint)
  }
}
