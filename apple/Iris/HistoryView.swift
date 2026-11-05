import IrisCore
import IrisUI
import SwiftUI

struct HistoryView: View {
  @Bindable var model: HistoryModel
  /// A server URL and token are saved. Without them there is nothing to load, and the list says how to connect.
  let isConfigured: Bool
  /// Opens Settings → Connection (the prompt's button).
  let onConnect: () -> Void
  /// Builds the detail model of a tapped row (the composition root owns the client and the media source).
  let makeDetail: (Memo) -> MemoDetailModel
  /// Builds the model of the composer sheet (the composition root owns the client).
  let makeComposer: (ComposerRequest) -> ComposerModel
  /// Builds the model of a conversation screen.
  let makeThread: (ThreadRoute) -> ThreadModel
  /// The mockup's row: 12 pt above and below, 20 pt screen margin on both sides (`history.html` `.row`).
  private static let rowInsets = EdgeInsets(
    top: Theme.Spacing.rowVertical, leading: Theme.Spacing.screenMargin, bottom: Theme.Spacing.rowVertical,
    trailing: Theme.Spacing.screenMargin)
  /// The day header draws its own margin: its solid backing has to reach both screen edges.
  private static let headerInsets = EdgeInsets()
  @State private var showingFilters = false
  @State private var composer: ComposerRequest?

  var body: some View {
    NavigationStack {
      List {
        // The title block and the chips are the list's first rows, not bars pinned with `safeAreaBar` around the list:
        // the list stays the navigation stack's root scroll content, so they scroll with it. The title is drawn here,
        // not by the navigation bar, so it sits on the same 20 pt margin as the rows (the system large title is 16).
        HistoryTitleBlock(
          title: String(localized: "History", comment: "Navigation title of the memo list"),
          subtitle: HistoryDaySection.subtitle(for: model.memos), onCompose: { composer = ComposerRequest() }
        )
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        HistoryFilterBar(
          filters: $model.filters, kinds: model.filters.kinds(in: model.memos, limit: HistoryFilters.kindChipLimit)
        )
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        let sections = model.sections
        ForEach(sections) { section in
          Section {
            ForEach(section.memos) { memo in
              NavigationLink(value: memo) {
                HistoryRow(
                  status: memo.rowStatus, headline: memo.rowHeadline, secondary: memo.rowSecondary,
                  timeText: memo.timeText, isDone: memo.done, isFavorite: memo.favorite,
                  isThread: memo.opensThread)
              }
              .accessibilityIdentifier("history.row")
              .listRowInsets(Self.rowInsets)
              .listRowBackground(HistoryRowBackground(needsAttention: false))
              .modifier(MemoSwipeActions(memo: memo, model: model))
              .task { await model.loadMoreIfNeeded(current: memo) }
            }
          } header: {
            Text(verbatim: section.title())
              .themeFont(.caption, weight: .semibold)
              .textCase(.uppercase)
              .foregroundStyle(Theme.Ink.muted)
              // The first label follows the chips, whose tap area already takes the top of that gap.
              .padding(
                .top,
                section.id == sections.first?.id
                  ? Theme.Spacing.sectionTop - Theme.Spacing.chipTapOverhang : Theme.Spacing.sectionTop
              )
              .padding(.bottom, Theme.Spacing.sectionBottom)
              .padding(.horizontal, Theme.Spacing.screenMargin)
              .frame(maxWidth: .infinity, alignment: .leading)
              // A pinned header is transparent by default: rows scrolled under it read through as ghost text.
              .background(Theme.Surface.background)
              .listRowInsets(Self.headerInsets)
          }
        }
      }
      .listStyle(.plain)
      .environment(\.defaultMinListHeaderHeight, 0)
      .environment(\.defaultMinListRowHeight, 0)
      .listSectionSpacing(.custom(0))
      .accessibilityIdentifier("history.list")
      .scrollContentBackground(.hidden)
      .background(Theme.Surface.background)
      .animation(.snappy, value: model.memoIDs)
      .overlay { emptyState }
      .takeBanner()
      .overlay(alignment: .bottom) { toastBanner }
      .navigationTitle(String(localized: "History", comment: "Navigation title of the memo list"))
      .toolbar(.hidden, for: .navigationBar)
      .navigationDestination(for: Memo.self) { memo in
        // A memo in a thread opens as a conversation; the rest is a single memo.
        if memo.opensThread, let route = memo.threadRoute {
          threadView(route)
        } else {
          BuiltOnce(make: { makeDetail(memo) }) { detail in
            MemoDetailView(
              model: detail, refreshToken: { model.revision(of: memo.id) },
              onReply: { composer = .reply(to: $0) })
          }
          .id(memo.id)
        }
      }
      .navigationDestination(for: ThreadRoute.self) { route in
        threadView(route)
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        HistorySearchBar(
          text: $model.filters.searchText, filterCount: model.filters.sheetFilterCount,
          onFilter: { showingFilters = true }
        )
        // Solid down to the screen edge: the Record accessory and the tab bar (also the minimized one under a take banner)
        // are glass over this, not over the rows.
        .floatingBarBackdrop(edge: .bottom)
      }
      .statusBarScrim()
      .scrollEdgeEffectStyle(.hard, for: .top)
      .sheet(isPresented: $showingFilters) {
        HistoryFilterSheet(
          filters: $model.filters,
          resultCount: HistoryResultCount.exact(
            memos: model.memos.count, isSettled: model.hasLoaded && !model.isLoading),
          kinds: model.filters.kinds(in: model.memos)
        )
        .presentationDragIndicator(.visible)
      }
      .sheet(item: $composer) { request in
        BuiltOnce(make: { makeComposer(request) }) { composer in
          ComposerView(model: composer, onSent: { model.insert($0) }, onQueued: { model.didQueue() })
        }
        .id(request.id)
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

  private func threadView(_ route: ThreadRoute) -> some View {
    BuiltOnce(make: { makeThread(route) }) { thread in
      ThreadView(
        model: thread,
        refreshToken: { threadId, ids in
          // Any event for a memo of the thread, or a new memo of it showing up in the list (another device's turn).
          let inThread = model.memos.count { $0.threadId == threadId }
          return ids.reduce(inThread) { $0 &+ model.revision(of: $1) }
        },
        makeComposer: makeComposer, onSent: { model.insert($0) })
    }
    .id(route.id)
  }

  /// How long the undo toast stays; UI tests stretch it (`-IrisUndoSeconds 60`) so a slow runner can still tap Undo.
  private var undoSeconds: Double {
    let override = UserDefaults.standard.double(forKey: "IrisUndoSeconds")
    return override > 0 ? override : 5
  }

  @ViewBuilder private var emptyState: some View {
    if !isConfigured {
      ContentUnavailableView {
        Label(
          String(localized: "Not connected", comment: "History title without a server connection"),
          systemImage: "network.slash")
      } description: {
        Text("Add your server URL and device token to see your memos.", comment: "History prompt without a connection")
      } actions: {
        Button(String(localized: "Open Settings", comment: "Opens Settings → Connection"), action: onConnect)
          .buttonStyle(.primary)
          .accessibilityIdentifier("history.connect")
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("history.connectPrompt")
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
        action: { Task { await model.undoDelete() } }
      )
      .padding(.horizontal, Theme.Spacing.barInset)
      .padding(.bottom, Theme.Spacing.barInset)
      .transition(.move(edge: .bottom).combined(with: .opacity))
      .accessibilityIdentifier("history.toast")
    }
  }
}
