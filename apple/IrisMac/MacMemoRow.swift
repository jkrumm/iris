import IrisCore
import IrisUI
import SwiftUI

/// One memo in the popover (`mac.html` `.menu .m`): the headline on one line with the time right, then a status dot and the
/// route / state in muted text. The context menu has the list's actions.
struct MacMemoRow: View {
  let root: MacCompositionRoot
  let model: HistoryModel
  let memo: Memo
  @State private var hovering = false

  var body: some View {
    Button {
      root.openDetail(memo.id)
    } label: {
      VStack(alignment: .leading, spacing: Theme.Spacing.menuRowLineGap) {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.cozy) {
          Text(verbatim: memo.rowHeadline)
            .themeFont(.footnote, weight: .semibold)
            .foregroundStyle(Theme.Ink.primary)
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 0)
          if memo.favorite {
            Image(systemName: "star.fill").foregroundStyle(Theme.Status.warn).accessibilityHidden(true)
          }
          if memo.done {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Status.good).accessibilityHidden(true)
          }
          Text(verbatim: memo.timeText)
            .monospacedDigit()
            .foregroundStyle(Theme.Ink.faint)
        }
        .themeFont(.caption)
        HStack(spacing: Theme.Spacing.snug) {
          Circle().fill(meta.dot).frame(width: 8, height: 8).accessibilityHidden(true)
          Text(verbatim: meta.text).lineLimit(1).truncationMode(.tail)
        }
        .themeFont(.caption)
        .foregroundStyle(Theme.Ink.muted)
      }
      .opacity(memo.done ? 0.55 : 1)
      .padding(.horizontal, Theme.Spacing.menuRowHorizontal)
      .padding(.vertical, Theme.Spacing.menuRowVertical)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(background, in: .rect(cornerRadius: Theme.Spacing.menuRowRadius))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .accessibilityIdentifier("mac.history.row")
    .contextMenu { actions }
  }

  /// Queues `action` for the memo: it runs after the memo's earlier actions, on the memo as it is then, and not at all when the
  /// connection changed first.
  private func act(_ action: @escaping @MainActor (HistoryModel, Memo) async -> Void) {
    root.perform(on: model, memoID: memo.id) { model in
      guard let current = model.memos.first(where: { $0.id == memo.id }) else { return }
      await action(model, current)
    }
  }

  @ViewBuilder private var actions: some View {
    Button(
      memo.done
        ? String(localized: "Not done", comment: "Context menu") : String(localized: "Done", comment: "Context menu"),
      systemImage: "checkmark"
    ) { act { await $0.toggleDone($1) } }
    Button(
      memo.favorite
        ? String(localized: "Unfavorite", comment: "Context menu")
        : String(localized: "Favorite", comment: "Context menu"),
      systemImage: memo.favorite ? "star.slash" : "star"
    ) { act { await $0.toggleFavorite($1) } }
    Button(
      memo.archived
        ? String(localized: "Unarchive", comment: "Context menu")
        : String(localized: "Archive", comment: "Context menu"),
      systemImage: memo.archived ? "tray.and.arrow.up" : "archivebox"
    ) { act { await $0.toggleArchived($1) } }
    if memo.state.isDeletable {
      Button("Delete", systemImage: "trash", role: .destructive) { act { await $0.delete($1) } }
    }
  }

  /// Plain rows: a hover lifts one. A memo that needs a route is marked by its orange dot, not a persistent box.
  private var background: Color { hovering ? Theme.Surface.subtle : .clear }

  private var meta: (dot: Color, text: String) {
    switch memo.rowStatus {
    case .settled(let route, let dot, let duration):
      (dot, [route, duration].compactMap { $0 }.joined(separator: " · "))
    case .inFlight(let route, let dot, let label, _):
      (dot, "\(route) · \(label)")
    case .alert(let label, let color):
      (color, label)
    }
  }
}
