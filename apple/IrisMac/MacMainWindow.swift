import IrisCore
import IrisUI
import SwiftUI

/// The main window "Iris": sidebar (library, conversations), the memo list and the selected memo, in a native three-column
/// `NavigationSplitView`. The window has a list model of its own (``MacCompositionRoot/windowHistory``), so its filters and search
/// never change the popover's home list.
struct MacMainWindow: View {
  @Bindable var root: MacCompositionRoot
  @State private var player = MacAudioPlayer()

  var body: some View {
    NavigationSplitView {
      MacSidebar(root: root)
        .navigationSplitViewColumnWidth(
          min: Theme.Spacing.windowSidebarMin, ideal: Theme.Spacing.windowSidebarIdeal,
          max: Theme.Spacing.windowSidebarIdeal + 40)
    } content: {
      MacMemoList(root: root, model: root.windowHistory, player: player)
        .navigationSplitViewColumnWidth(
          min: Theme.Spacing.windowListMin, ideal: Theme.Spacing.windowListIdeal,
          max: Theme.Spacing.windowListIdeal + 120)
    } detail: {
      detail
    }
    .navigationTitle(String(localized: "Iris", comment: "Main window title"))
    .navigationSubtitle(subtitle)
    .frame(
      minWidth: Theme.Spacing.windowSidebarMin + Theme.Spacing.windowListMin + Theme.Spacing.windowDetailMin,
      minHeight: 480
    )
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Button(
          String(localized: "New memo", comment: "Main window toolbar: opens the New memo page"),
          systemImage: "square.and.pencil"
        ) {
          root.newMemo()
        }
        .keyboardShortcut("n")
        .help(String(localized: "New memo", comment: "Main window toolbar: opens the New memo page"))
        .accessibilityIdentifier("mac.toolbar.new-memo")
      }
    }
    .environment(\.replyImageStore, root.replyImages)
    .macToast(root: root, model: root.windowHistory)
    .onAppear {
      root.windowDidAppear()
      root.noteWindow("main", "open")
    }
    .onDisappear {
      player.stop()
      root.windowDidDisappear()
      root.noteWindow("main", "close")
    }
    .accessibilityIdentifier("mac.window")
  }

  @ViewBuilder private var detail: some View {
    if let id = root.selectedMemoID {
      // A new id is a new memo: the pane and its model start over.
      MacMemoDetailPane(root: root, model: root.detailModel(for: id), player: player)
        .id(id)
    } else {
      MacNewMemoPage(root: root)
    }
  }

  private var subtitle: String {
    switch root.scope ?? .all {
    case .all: String(localized: "All memos", comment: "Sidebar item")
    case .favorites: String(localized: "Favorites", comment: "Sidebar item")
    case .archive: String(localized: "Archive", comment: "Sidebar item")
    case .threads: String(localized: "Threads", comment: "Sidebar item")
    }
  }
}
