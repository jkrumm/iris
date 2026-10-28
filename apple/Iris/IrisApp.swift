import SwiftUI

@main
struct IrisApp: App {
  @State private var root = CompositionRoot()

  var body: some Scene {
    WindowGroup {
      RootView(
        history: root.history, stats: root.stats, settings: root.settings, diagnostics: root.diagnostics,
        makeDetail: root.detailModel(for:), makeComposer: root.composerModel(for:)
      )
      .task { await root.start() }
    }
  }
}
