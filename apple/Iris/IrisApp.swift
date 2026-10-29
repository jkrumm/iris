import SwiftUI

@main
struct IrisApp: App {
  @State private var root = CompositionRoot()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      RootView(
        history: root.history, isConfigured: root.isConfigured, take: root.take, stats: root.stats,
        settings: root.settings,
        diagnostics: root.diagnostics, micRules: root.micRules, spokenReplies: root.spokenReplies,
        connectionForm: root.connectionForm, startsOnSettings: root.opensOnSettings,
        makeDetail: root.detailModel(for:), makeComposer: root.composerModel(for:),
        makeThread: root.threadModel(for:), makeRouteAnswer: root.routeAnswerModel(for:)
      )
      .environment(\.replyImageStore, root.replyImages)
      .task(id: root.connectionRevision) { await root.start() }
      .onChange(of: scenePhase) { _, phase in
        root.spokenReplies.isForeground = phase == .active
        guard phase == .active else { return }
        Task { await root.foregrounded() }
      }
    }
  }
}
