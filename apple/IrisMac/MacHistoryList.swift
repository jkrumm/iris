import IrisCore
import IrisUI
import SwiftUI

/// History in the menu-bar panel: the iOS list's rows (``HistoryRow``), day sections, filter chips and search, on the same
/// ``HistoryModel``. A click opens the memo in the detail panel; the context menu has the swipe actions.
struct MacHistoryList: View {
  let root: MacCompositionRoot
  @Bindable var model: HistoryModel

  var body: some View {
    VStack(spacing: 0) {
      TextField(
        String(localized: "Search transcripts", comment: "Search field prompt on the memo list"),
        text: $model.filters.searchText
      )
      .textFieldStyle(.roundedBorder)
      .padding(.horizontal, Theme.Spacing.lg)
      .padding(.top, Theme.Spacing.sm)
      .accessibilityIdentifier("mac.history.search")
      HistoryFilterBar(filters: $model.filters)
      List {
        ForEach(HistoryDaySection.group(model.memos)) { section in
          Section {
            ForEach(section.memos) { memo in
              row(memo)
                .task { await model.loadMoreIfNeeded(current: memo) }
            }
          } header: {
            Text(verbatim: section.title())
              .themeFont(.caption, weight: .semibold)
              .textCase(.uppercase)
              .foregroundStyle(Theme.Ink.muted)
          }
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .animation(.snappy, value: model.memos.map(\.id))
      .overlay { emptyState }
      .overlay(alignment: .bottom) { toastBanner }
      .accessibilityIdentifier("mac.history.list")
    }
    .task(id: model.filters) {
      guard root.isConfigured else { return }
      // Typing restarts this task, so only the last keystroke of a burst reaches the server.
      if !model.filters.searchText.isEmpty {
        guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
      }
      await model.load()
    }
    .task(id: model.toast?.id) {
      guard let id = model.toast?.id, (try? await Task.sleep(for: .seconds(5))) != nil else { return }
      model.dismissToast(id: id)
    }
  }

  /// Queues `action` for `memo`: it runs after the memo's earlier actions, on the memo as it is then (a second tap on a favorite
  /// toggles the state the first one left), and not at all when the connection changed first.
  private func act(on memo: Memo, _ action: @escaping @MainActor (HistoryModel, Memo) async -> Void) {
    root.perform(on: model, memoID: memo.id) { model in
      guard let current = model.memos.first(where: { $0.id == memo.id }) else { return }
      await action(model, current)
    }
  }

  private func row(_ memo: Memo) -> some View {
    Button {
      root.openDetail(memo.id)
    } label: {
      HistoryRow(
        status: memo.rowStatus, headline: memo.rowHeadline, secondary: memo.rowSecondary, timeText: memo.timeText,
        isDone: memo.done, isFavorite: memo.favorite
      )
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("mac.history.row")
    .listRowBackground(HistoryRowBackground(needsAttention: memo.isOpenNeedsRoute))
    .contextMenu {
      Button(memo.done ? "Not done" : "Done", systemImage: "checkmark") {
        act(on: memo) { await $0.toggleDone($1) }
      }
      Button(memo.favorite ? "Unfavorite" : "Favorite", systemImage: memo.favorite ? "star.slash" : "star") {
        act(on: memo) { await $0.toggleFavorite($1) }
      }
      Button(memo.archived ? "Unarchive" : "Archive", systemImage: memo.archived ? "tray.and.arrow.up" : "archivebox") {
        act(on: memo) { await $0.toggleArchived($1) }
      }
      if memo.state.isDeletable {
        Button("Delete", systemImage: "trash", role: .destructive) { act(on: memo) { await $0.delete($1) } }
      }
    }
  }

  @ViewBuilder private var emptyState: some View {
    if !root.isConfigured {
      ContentUnavailableView {
        Label(
          String(localized: "Not connected", comment: "History title without a server connection"),
          systemImage: "network.slash")
      } description: {
        Text("Add your server URL and device token to see your memos.", comment: "History prompt without a connection")
      } actions: {
        Button(String(localized: "Open Settings", comment: "Opens Settings → Connection")) { root.page = .settings }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("mac.history.connect")
      }
    } else if model.loadFailed && model.memos.isEmpty {
      ContentUnavailableView(
        String(localized: "Could not load memos", comment: "History error title"),
        systemImage: "exclamationmark.triangle")
    } else if model.hasLoaded && !model.isLoading && model.memos.isEmpty {
      if model.filters.searchText.isEmpty {
        ContentUnavailableView(
          String(localized: "No memos", comment: "History empty title"), systemImage: "tray",
          description: model.filters.isFiltering
            ? Text("No memo matches these filters.", comment: "History empty description") : nil)
      } else {
        ContentUnavailableView.search
      }
    }
  }

  @ViewBuilder private var toastBanner: some View {
    if let toast = model.toast {
      ToastBanner(
        message: toast.message,
        actionTitle: toast.kind.isUndo ? String(localized: "Undo", comment: "Undoes a delete") : nil,
        action: { root.perform(on: model) { await $0.undoDelete() } }
      )
      .padding(Theme.Spacing.lg)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .accessibilityIdentifier("mac.history.toast")
    }
  }
}
