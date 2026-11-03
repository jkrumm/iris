import IrisCore
import IrisUI
import SwiftUI

/// History inside the popover: the same compact row as the home page (``MacMemoRow``), a plain search field, filter chips that
/// scroll sideways without a visible scroller, and the day sections.
struct MacHistoryPage: View {
  let root: MacCompositionRoot
  @Bindable var model: HistoryModel

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      MacPageHeader(title: String(localized: "History", comment: "Panel page")) { root.goHome() }
      MacOutboxStrip(model: root.outbox)
      search
      chips
      list
    }
    .padding(Theme.Spacing.menuInset)
    .frame(height: Theme.Spacing.menuPageHeight)
    .task(id: model.filters) {
      guard root.isConfigured else { return }
      // Typing restarts this task, so only the last keystroke of a burst reaches the server.
      if !model.filters.searchText.isEmpty {
        guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
      }
      await model.load()
    }
  }

  private var search: some View {
    HStack(spacing: Theme.Spacing.snug) {
      Image(systemName: "magnifyingglass").foregroundStyle(Theme.Ink.faint).accessibilityHidden(true)
      TextField(
        String(localized: "Search transcripts", comment: "Search field prompt on the memo list"),
        text: $model.filters.searchText
      )
      .textFieldStyle(.plain)
      .accessibilityIdentifier("mac.history.search")
    }
    .themeFont(.footnote)
    .padding(.horizontal, Theme.Spacing.cozy)
    .padding(.vertical, Theme.Spacing.snug)
    .background(Theme.Surface.subtle, in: .rect(cornerRadius: Theme.Spacing.menuLineRadius))
  }

  private var chips: some View {
    ScrollView(.horizontal) {
      HStack(spacing: Theme.Spacing.chipGap) {
        ForEach(QuickFilter.allCases, id: \.self) { filter in
          MacFilterChip(title: filter.title, isOn: model.filters.quick == filter) {
            withAnimation(.snappy) { model.filters.toggle(filter) }
          }
          .accessibilityIdentifier("mac.history.chip.\(String(describing: filter))")
        }
      }
    }
    .scrollIndicators(.hidden)
    .frame(height: Theme.Spacing.menuChipHeight)
  }

  private var list: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: Theme.Spacing.menuGap, pinnedViews: []) {
        let sections = HistoryDaySection.group(model.memos)
        ForEach(sections) { section in
          Text(verbatim: section.title())
            .themeFont(.caption, weight: .semibold)
            .textCase(.uppercase)
            .foregroundStyle(Theme.Ink.muted)
            .padding(.horizontal, Theme.Spacing.menuRowHorizontal)
            .padding(.top, section.id == sections.first?.id ? Theme.Spacing.xs : Theme.Spacing.sectionTop)
            .padding(.bottom, Theme.Spacing.xs)
          ForEach(section.memos) { memo in
            MacMemoRow(root: root, model: model, memo: memo)
              .task { await model.loadMoreIfNeeded(current: memo) }
          }
        }
      }
    }
    .scrollIndicators(.automatic)
    .animation(.snappy, value: model.memoIDs)
    .overlay { emptyState }
    .accessibilityIdentifier("mac.history.list")
  }

  @ViewBuilder private var emptyState: some View {
    if !root.isConfigured {
      Text("Add your server URL and device token to see your memos.", comment: "History prompt without a connection")
        .themeFont(.footnote).foregroundStyle(Theme.Ink.muted).multilineTextAlignment(.center)
    } else if model.loadFailed && model.memos.isEmpty {
      emptyLabel(String(localized: "Could not load memos", comment: "History error title"))
    } else if model.hasLoaded && !model.isLoading && model.memos.isEmpty {
      emptyLabel(
        model.filters.searchText.isEmpty && !model.filters.isFiltering
          ? String(localized: "No memos", comment: "History empty title")
          : String(localized: "No memo matches these filters.", comment: "History empty description"))
    }
  }

  private func emptyLabel(_ text: String) -> some View {
    Text(verbatim: text).themeFont(.footnote).foregroundStyle(Theme.Ink.faint)
  }
}

/// A Mac-sized quick-filter chip (title only, so the four fit the popover's width): small text, a fixed short height, no extra tap area.
private struct MacFilterChip: View {
  let title: String
  let isOn: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(verbatim: title).lineLimit(1)
        .themeFont(.caption, weight: .medium)
        .foregroundStyle(isOn ? Theme.Accent.onFill : Theme.Ink.secondary)
        .padding(.horizontal, Theme.Spacing.cozy)
        .frame(height: Theme.Spacing.menuChipHeight)
        .background(isOn ? Theme.Accent.fill : Theme.Surface.subtle, in: .capsule)
        .overlay { Capsule().strokeBorder(Theme.Surface.border, lineWidth: isOn ? 0 : 0.5) }
        .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}
