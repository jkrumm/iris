import IrisCore
import IrisUI
import SwiftUI

/// The list actions of a memo (done, favorite, archive, delete) on one ``HistoryModel``: the popover's rows, the main window's
/// list, its context menu and the detail's toolbar all go through here.
///
/// Each action is queued for the memo: it runs after the memo's earlier actions, on the memo as it is then, and not at all when the
/// connection changed first (``MacCompositionRoot/perform(on:memoID:_:)``).
@MainActor
struct MacMemoActions {
  let root: MacCompositionRoot
  let model: HistoryModel

  func toggleDone(_ memo: Memo) { act(memo) { await $0.toggleDone($1) } }
  func toggleFavorite(_ memo: Memo) { act(memo) { await $0.toggleFavorite($1) } }
  func toggleArchived(_ memo: Memo) { act(memo) { await $0.toggleArchived($1) } }
  /// Delete is queued at the tap: the selection goes at once (the deleted memo leaves the list, so the detail has nothing to show),
  /// and a second tap for the same memo does nothing while the first is waiting or running.
  func delete(_ memo: Memo) {
    guard memo.state.isDeletable, root.beginDelete(memo.id) else { return }
    if root.selectedMemoID == memo.id { root.selectedMemoID = nil }
    act(memo) { [root] model, current in
      defer { root.endDelete(current.id) }
      await model.delete(current)
    } onDropped: { [root] in
      root.endDelete(memo.id)
    }
  }

  /// Queues the action for the memo; it resolves the memo in the list when it runs, on the memo as it is then (the list must hold it:
  /// see ``MacCompositionRoot/ensureHeld(_:)``). A memo the list no longer holds is skipped.
  private func act(
    _ memo: Memo, _ action: @escaping @MainActor (HistoryModel, Memo) async -> Void,
    onDropped: (@MainActor () -> Void)? = nil
  ) {
    root.perform(on: model, memoID: memo.id) { model in
      guard let current = model.memos.first(where: { $0.id == memo.id }) else {
        onDropped?()
        return
      }
      await action(model, current)
    }
  }
}

/// The context menu of a memo row.
struct MacMemoContextMenu: View {
  let actions: MacMemoActions
  let memo: Memo

  var body: some View {
    Button(
      memo.done
        ? String(localized: "Not done", comment: "Context menu") : String(localized: "Done", comment: "Context menu"),
      systemImage: "checkmark"
    ) { actions.toggleDone(memo) }
    Button(
      memo.favorite
        ? String(localized: "Unfavorite", comment: "Context menu")
        : String(localized: "Favorite", comment: "Context menu"),
      systemImage: memo.favorite ? "star.slash" : "star"
    ) { actions.toggleFavorite(memo) }
    Button(
      memo.archived
        ? String(localized: "Unarchive", comment: "Context menu")
        : String(localized: "Archive", comment: "Context menu"),
      systemImage: memo.archived ? "tray.and.arrow.up" : "archivebox"
    ) { actions.toggleArchived(memo) }
    if memo.state.isDeletable {
      Divider()
      Button("Delete", systemImage: "trash", role: .destructive) { actions.delete(memo) }
    }
  }
}

extension Memo {
  /// The status dot and the line next to it on a row: the kind and the audio length, the state of a memo that needs the user.
  var macRowMeta: (dot: Color, text: String) {
    switch rowStatus {
    case .settled(let kind, let dot, let duration):
      (dot, [kind, duration].compactMap { $0 }.joined(separator: " · "))
    case .inFlight(let kind, let dot, let label, _):
      (dot, "\(kind) · \(label)")
    case .alert(let label, let color):
      (color, label)
    }
  }
}

/// The undo toast of a delete, at the foot of the popover and of the main window; it ends itself after five seconds.
private struct MacToastModifier: ViewModifier {
  let root: MacCompositionRoot
  let model: HistoryModel

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottom) {
        if let toast = model.toast {
          ToastBanner(
            message: toast.message,
            actionTitle: toast.kind.isUndo ? String(localized: "Undo", comment: "Undoes a delete") : nil,
            action: { root.perform(on: model) { await $0.undoDelete() } }
          )
          .padding(Theme.Spacing.sm)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .accessibilityIdentifier("mac.history.toast")
        }
      }
      .task(id: model.toast?.id) {
        guard let id = model.toast?.id, (try? await Task.sleep(for: .seconds(5))) != nil else { return }
        model.dismissToast(id: id)
      }
  }
}

extension View {
  func macToast(root: MacCompositionRoot, model: HistoryModel) -> some View {
    modifier(MacToastModifier(root: root, model: model))
  }
}
