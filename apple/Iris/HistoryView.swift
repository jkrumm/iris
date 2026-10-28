import IrisCore
import IrisUI
import SwiftUI

struct HistoryView: View {
  @Bindable var model: HistoryModel
  @State private var showingFilters = false

  var body: some View {
    NavigationStack {
      List {
        ForEach(HistoryDaySection.group(model.memos)) { section in
          Section {
            ForEach(section.memos) { memo in
              NavigationLink(value: memo) {
                HistoryRow(
                  status: memo.rowStatus, headline: memo.rowHeadline, secondary: memo.rowSecondary,
                  timeText: memo.timeText, isDone: memo.done, isFavorite: memo.favorite)
              }
              .accessibilityIdentifier("history.row")
              .listRowBackground(HistoryRowBackground(needsAttention: memo.isOpenNeedsRoute))
              .modifier(MemoSwipeActions(memo: memo, model: model))
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
      .accessibilityIdentifier("history.list")
      .scrollContentBackground(.hidden)
      .background(Theme.Surface.background)
      .animation(.snappy, value: model.memos.map(\.id))
      .overlay { emptyState }
      .safeAreaBar(edge: .top, spacing: 0) {
        HistoryFilterBar(filters: $model.filters)
      }
      .overlay(alignment: .bottom) { toastBanner }
      .navigationTitle(String(localized: "History", comment: "Navigation title of the memo list"))
      .navigationSubtitle(HistoryDaySection.subtitle(for: model.memos) ?? "")
      .navigationDestination(for: Memo.self) { memo in
        MemoDetailView(memo: memo)
      }
      .searchable(
        text: $model.filters.searchText,
        prompt: String(localized: "Search transcripts", comment: "Search field prompt on the memo list")
      )
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(String(localized: "Filter", comment: "Opens the filter sheet"), systemImage: filterIcon) {
            showingFilters = true
          }
          .accessibilityIdentifier("history.filter")
        }
      }
      .sheet(isPresented: $showingFilters) {
        HistoryFilterSheet(filters: $model.filters)
          .presentationDetents([.medium])
          .presentationDragIndicator(.visible)
      }
      .refreshable { await model.load() }
      .task(id: model.filters) {
        // Typing restarts this task, so only the last keystroke of a burst reaches the server.
        if !model.filters.searchText.isEmpty {
          guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
        }
        await model.load()
      }
      .task(id: model.toast?.id) {
        guard let id = model.toast?.id, (try? await Task.sleep(for: .seconds(undoSeconds))) != nil else { return }
        model.dismissToast(id: id)
      }
    }
  }

  /// How long the undo toast stays; UI tests stretch it (`-IrisUndoSeconds 60`) so a slow runner can still tap Undo.
  private var undoSeconds: Double {
    let override = UserDefaults.standard.double(forKey: "IrisUndoSeconds")
    return override > 0 ? override : 5
  }

  private var filterIcon: String {
    model.filters.sheetFilterCount > 0
      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
  }

  @ViewBuilder private var emptyState: some View {
    if model.loadFailed && model.memos.isEmpty {
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
        actionTitle: toast.kind == .error ? nil : String(localized: "Undo", comment: "Undoes a delete"),
        action: { Task { await model.undoDelete() } }
      )
      .padding(.horizontal, Theme.Spacing.lg)
      .padding(.bottom, Theme.Spacing.lg)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .accessibilityIdentifier("history.toast")
    }
  }
}
