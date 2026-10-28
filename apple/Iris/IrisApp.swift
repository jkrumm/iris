import SwiftUI

@main
struct IrisApp: App {
  @State private var root = CompositionRoot()

  var body: some Scene {
    WindowGroup {
      RootView(history: root.history)
        .task { await root.start() }
    }
  }
}
