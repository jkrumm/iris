import SwiftUI

@main
struct IrisMacApp: App {
  @State private var root = MacCompositionRoot()

  var body: some Scene {
    MenuBarExtra(String(localized: "Iris", comment: "Menu bar item title"), systemImage: "waveform") {
      RecentMemosPanel(model: root.history)
        .task { await root.start() }
    }
    .menuBarExtraStyle(.window)
  }
}
