import SwiftUI

@main
struct IrisApp: App {
  @State private var root = CompositionRoot()
  @Environment(\.scenePhase) private var scenePhase

  init() {
    DeviceLog.shared.start()
  }

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
      .task { DeviceLog.shared.sceneChanged(to: scenePhase.telemetryName) }
      .task(id: root.connectionRevision) { await root.start() }
      .onChange(of: scenePhase) { _, phase in
        DeviceLog.shared.sceneChanged(to: phase.telemetryName)
        root.spokenReplies.isForeground = phase == .active
        guard phase == .active else { return }
        Task { await root.foregrounded() }
      }
    }
  }
}

extension ScenePhase {
  /// The name `app.lifecycle` and the ambient `app.state` carry.
  var telemetryName: String {
    switch self {
    case .active: "active"
    case .inactive: "inactive"
    case .background: "background"
    @unknown default: "unknown"
    }
  }
}
