import SwiftUI

@main
struct IrisApp: App {
  @State private var root = CompositionRoot()

  var body: some Scene {
    WindowGroup {
      RootView(
        history: root.history, stats: root.stats, settings: root.settings, diagnostics: root.diagnostics,
        connectionForm: root.connectionForm, startsOnSettings: root.opensOnSettings,
        makeDetail: root.detailModel(for:), makeComposer: root.composerModel(for:),
        makeThread: root.threadModel(for:)
      )
      .environment(\.replyImageStore, root.replyImages)
      .task(id: root.connectionRevision) { await root.start() }
    }
  }
}
