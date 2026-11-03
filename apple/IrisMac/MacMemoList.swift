import IrisCore
import IrisUI
import SwiftUI

/// The main window's list column: the window's own ``HistoryModel`` in day sections on a native `List` (selection highlight,
/// arrow keys), search in the toolbar, paging as the end comes into view. Delete removes the selected memo (with the undo toast),
/// Space plays its recording.
struct MacMemoList: View {
  @Bindable var root: MacCompositionRoot
  @Bindable var model: HistoryModel
  let player: MacAudioPlayer

  var body: some View {
    List(selection: $root.selectedMemoID) {
      ForEach(model.sections) { section in
        Section {
          ForEach(section.memos) { memo in
            MacMemoListRow(memo: memo)
              .tag(memo.id)
              .contextMenu { MacMemoContextMenu(actions: actions, memo: memo) }
              .task { await model.loadMoreIfNeeded(current: memo) }
          }
        } header: {
          Text(verbatim: section.title())
            .macFont(.caption, weight: .semibold)
            .textCase(.uppercase)
        }
      }
    }
    .listStyle(.inset)
    .environment(\.defaultMinListRowHeight, Theme.Spacing.macRowMinHeight)
    .overlay { emptyState }
    .searchable(
      text: $model.filters.searchText, placement: .toolbar,
      prompt: String(localized: "Search transcripts", comment: "Search field prompt on the memo list")
    )
    .onDeleteCommand { if let memo = selected { actions.delete(memo) } }
    .onKeyPress(.space) {
      guard let memo = selected, let request = root.mediaSource.audio(for: memo) else { return .ignored }
      player.toggle(memo.id, .recording, request: request)
      return .handled
    }
    .task(id: model.filters) {
      guard root.isConfigured else { return }
      // Typing restarts this task, so only the last keystroke of a burst reaches the server.
      if !model.filters.searchText.isEmpty {
        guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
      }
      await model.load()
    }
    .accessibilityIdentifier("mac.list")
  }

  private var actions: MacMemoActions { MacMemoActions(root: root, model: model) }

  private var selected: Memo? {
    root.selectedMemoID.flatMap { id in model.memos.first { $0.id == id } }
  }

  @ViewBuilder private var emptyState: some View {
    if !root.isConfigured {
      ContentUnavailableView {
        Label(
          String(localized: "Not connected", comment: "Empty list without a connection"), systemImage: "bolt.horizontal"
        )
      } description: {
        Text("Add your server URL and device token to see your memos.", comment: "History prompt without a connection")
      } actions: {
        Button(String(localized: "Set Up Iris", comment: "Opens the onboarding window")) { root.showOnboarding() }
      }
    } else if model.loadFailed && model.memos.isEmpty {
      ContentUnavailableView(
        String(localized: "Could not load memos", comment: "History error title"),
        systemImage: "exclamationmark.triangle")
    } else if model.hasLoaded && !model.isLoading && model.memos.isEmpty {
      if !model.filters.searchText.isEmpty {
        ContentUnavailableView.search(text: model.filters.searchText)
      } else {
        ContentUnavailableView(
          String(localized: "No memos", comment: "History empty title"), systemImage: "waveform")
      }
    }
  }
}
