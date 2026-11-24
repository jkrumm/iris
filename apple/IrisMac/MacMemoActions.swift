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

  /// The Delete of the toolbar, the context menu and the Delete key: it asks first (a dialog with Delete, Archive instead and Cancel,
  /// MacDeleteConfirmation) and does nothing while the memo's earlier delete is still queued. Nothing is deleted until
  /// answer(_:_:) is called with .delete.
  func requestDelete(_ memo: Memo) {
    guard memo.state.isDeletable, !root.deletingIDs.contains(memo.id) else { return }
    root.deleteRequest = MacDeleteRequest(memo: memo, inWindow: model === root.windowHistory)
  }

  /// The answer to the dialog: Delete runs the queued delete (its undo toast stays), Archive instead archives the memo and keeps it,
  /// Cancel changes nothing.
  func answer(_ request: MacDeleteRequest, _ choice: MacDeleteChoice) {
    root.deleteRequest = nil
    switch choice {
    case .delete: delete(request.memo)
    case .archive: if !request.memo.archived { toggleArchived(request.memo) }
    case .cancel: break
    }
  }
  /// Delete is queued at the tap: the selection goes at once (the deleted memo leaves the list, so the detail has nothing to show),
  /// and a second tap for the same memo does nothing while the first is waiting or running. The selection goes when it is any turn of
  /// the row's conversation (a banner may have opened an older one): the whole thread is deleted.
  func delete(_ memo: Memo) {
    guard memo.state.isDeletable, root.beginDelete(memo.id) else { return }
    if root.selection(isPartOf: memo) { root.selectedMemoID = nil }
    act(memo) { [root] model, current in
      defer { root.endDelete(memo.id) }
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
      guard let current = model.row(for: memo) else {
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
    if memo.macRowCopyText != nil {
      Button(String(localized: "Copy transcript", comment: "Detail toolbar menu"), systemImage: "doc.on.doc") {
        Task {
          if let text = await actions.root.wholeTranscript(of: memo) { MacPasteboard().copy(text) }
        }
      }
      .help(MacMemoControl.copyTranscriptRow.help)
      Divider()
    }
    Button(
      memo.done
        ? String(localized: "Not done", comment: "Context menu") : String(localized: "Done", comment: "Context menu"),
      systemImage: "checkmark"
    ) { actions.toggleDone(memo) }
    .help((memo.done ? MacMemoControl.notDone : .done).help)
    Button(
      memo.favorite
        ? String(localized: "Unfavorite", comment: "Context menu")
        : String(localized: "Favorite", comment: "Context menu"),
      systemImage: memo.favorite ? "star.slash" : "star"
    ) { actions.toggleFavorite(memo) }
    .help((memo.favorite ? MacMemoControl.unfavorite : .favorite).help)
    Button(
      memo.archived
        ? String(localized: "Unarchive", comment: "Context menu")
        : String(localized: "Archive", comment: "Context menu"),
      systemImage: memo.archived ? "tray.and.arrow.up" : "archivebox"
    ) { actions.toggleArchived(memo) }
    .help((memo.archived ? MacMemoControl.unarchive : .archive).help)
    if memo.state.isDeletable {
      Divider()
      Button("Delete", systemImage: "trash", role: .destructive) { actions.requestDelete(memo) }
        .help(MacMemoControl.delete.help)
    }
  }
}

/// A Delete waiting for the user's answer: the memo (the list's row, so a conversation is deleted whole) and the surface that asked,
/// the main window or the popover, each of which shows its own dialog.
struct MacDeleteRequest: Identifiable {
  let memo: Memo
  let inWindow: Bool
  var id: String { memo.id }
}

enum MacDeleteChoice { case delete, archive, cancel }

/// The dialog of a Delete: Delete, Archive instead (not offered for a memo that is archived already) and Cancel. Return takes Cancel,
/// the safe button, as the macOS guidelines have it for a destructive action; Escape too.
private struct MacDeleteConfirmation: ViewModifier {
  let root: MacCompositionRoot
  let inWindow: Bool

  func body(content: Content) -> some View {
    let request = root.deleteRequest.flatMap { $0.inWindow == inWindow ? $0 : nil }
    content.confirmationDialog(
      String(localized: "Delete this memo?", comment: "Delete confirmation title"),
      isPresented: Binding(get: { request != nil }, set: { if !$0 { root.deleteRequest = nil } }),
      titleVisibility: .visible, presenting: request
    ) { request in
      let actions = MacMemoActions(root: root, model: inWindow ? root.windowHistory : root.history)
      if !request.memo.archived {
        Button(String(localized: "Archive instead", comment: "Delete confirmation: keeps the memo in the archive")) {
          actions.answer(request, .archive)
        }
        .help(String(localized: "Move the memo to the archive and keep it", comment: "Tooltip of Archive instead"))
      }
      Button(String(localized: "Delete", comment: "Delete confirmation: deletes the memo"), role: .destructive) {
        actions.answer(request, .delete)
      }
      .help(MacMemoControl.delete.help)
      Button(String(localized: "Cancel", comment: "Delete confirmation: keeps everything as it is"), role: .cancel) {
        actions.answer(request, .cancel)
      }
      .keyboardShortcut(.defaultAction)
      .help(String(localized: "Keep the memo", comment: "Tooltip of Cancel in the delete confirmation"))
    } message: { _ in
      Text(
        "It disappears on every device. Right after, Undo brings it back for a few seconds; archiving keeps it for good.",
        comment: "Delete confirmation message")
    }
  }
}

extension View {
  /// Asks before a Delete of the surface (inWindow: the main window, else the popover).
  func macDeleteConfirmation(root: MacCompositionRoot, inWindow: Bool) -> some View {
    modifier(MacDeleteConfirmation(root: root, inWindow: inWindow))
  }
}

/// The mark before a row's status line: the status dot, or a small spinner while the memo is still in the pipeline, so a running
/// turn reads as alive (the dot under Reduce Motion).
struct MacRowStatusMark: View {
  let memo: Memo
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if memo.macIsRunning && !reduceMotion {
      ProgressView()
        .controlSize(.mini)
        .frame(width: Theme.Spacing.macDot, height: Theme.Spacing.macDot)
        .accessibilityHidden(true)
    } else {
      Circle()
        .fill(memo.macRowMeta.dot)
        .frame(width: Theme.Spacing.macDot, height: Theme.Spacing.macDot)
        .accessibilityHidden(true)
    }
  }
}

/// The Copy of a transcript row, shown while the pointer is over the row: it puts the memo's whole transcript (every part of a
/// continued one) on the pasteboard without opening the memo and says "Copied" for a moment. Not part of the row's selection or click.
struct MacRowCopyButton: View {
  let root: MacCompositionRoot
  let memo: Memo
  @State private var requests = 0
  @State private var copied = false

  var body: some View {
    Button {
      requests += 1
    } label: {
      Label(
        copied
          ? String(localized: "Copied", comment: "Detail: confirmation after Copy")
          : String(localized: "Copy", comment: "Detail: copies the section as plain text"),
        systemImage: copied ? "checkmark" : "doc.on.doc"
      )
      .labelStyle(.iconOnly)
      .macFont(.caption)
      .frame(width: Theme.Spacing.macRowCopySize, height: Theme.Spacing.macRowCopySize)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help(MacMemoControl.copyTranscriptRow.help)
    // The copy and its confirmation run in the view's task, so a row that leaves the list takes them along.
    .task(id: requests) {
      guard requests > 0, let text = await root.wholeTranscript(of: memo) else { return }
      MacPasteboard().copy(text)
      copied = true
      guard (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
      copied = false
    }
    .accessibilityIdentifier("mac.row.copy")
  }
}

extension Memo {
  /// Whether a row offers Copy, and the memo's own words: the transcript of a Transcribe memo, nil for any other (a Hermes memo is
  /// read as a conversation, and a memo without a transcript has nothing to copy). What is copied is the whole transcript,
  /// ``MacCompositionRoot/wholeTranscript(of:)``.
  var macRowCopyText: String? { mode == .transcribe ? plainTranscript : nil }

  /// The memo is still in the pipeline: not finished and not failed.
  var macIsRunning: Bool { !state.isResultReady && state != .failed && state != .receiving }

  /// The status dot and the line next to it on a row: the kind and the audio length, the state of a memo that needs the user.
  var macRowMeta: (dot: Color, text: String) {
    switch rowStatus {
    case .settled(let kind, let dot, let duration):
      (dot, [kind, duration].compactMap { $0 }.joined(separator: " · "))
    case .inFlight(let kind, let dot, let label, _):
      (dot, "\(kind) · \(label)")
    case .alert(let label, let color), .recording(let label, let color):
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
