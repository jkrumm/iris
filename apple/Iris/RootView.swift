import IrisCore
import IrisUI
import SwiftUI

/// History · Stats · Settings. Threads are not a tab: a conversation is a History row (round 2).
struct RootView: View {
  let history: HistoryModel
  let makeDetail: (Memo) -> MemoDetailModel

  var body: some View {
    TabView {
      Tab(String(localized: "History", comment: "Tab title"), systemImage: "clock") {
        HistoryView(model: history, makeDetail: makeDetail)
      }
      Tab(String(localized: "Stats", comment: "Tab title"), systemImage: "chart.bar") {
        PlaceholderTab(title: String(localized: "Stats", comment: "Navigation title of the Stats placeholder"))
          .accessibilityIdentifier("stats.placeholder")
      }
      Tab(String(localized: "Settings", comment: "Tab title"), systemImage: "gearshape") {
        PlaceholderTab(title: String(localized: "Settings", comment: "Navigation title of the Settings placeholder"))
          .accessibilityIdentifier("settings.placeholder")
      }
    }
    .tint(Theme.Accent.tint)
  }
}
