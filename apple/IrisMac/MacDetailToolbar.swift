import IrisCore
import IrisUI
import SwiftUI

extension View {
  /// The ink of a toolbar control: the system's label color, the one the plain buttons draw in. The window's tint is the accent
  /// (selection, focus rings) and a Menu would take it, so every toolbar control sets this, and the toolbar reads as one grey row.
  func macToolbarInk() -> some View { tint(.primary) }
}

/// The detail toolbar's controls of one memo, in two groups: `primary` (read, copy, retry, play the recording, details) and
/// `flags` (favorite, archive, delete). The pane puts each in a toolbar group; the snapshot run draws the same two in a strip of
/// ours, because the window's own toolbar comes out blank on a host with no display.
struct MacDetailToolbar {
  let root: MacCompositionRoot
  let model: MacMemoDetailModel
  let player: MacAudioPlayer
  let memo: Memo
  /// The memo's row in the window's list when the list holds one: a conversation's row is its newest memo, so the flags and Delete
  /// read and act on it (its state, the thread's favorite), while the controls above stay on the memo that is open.
  var row: Memo?

  private var flagged: Memo { row ?? memo }

  @ViewBuilder var primary: some View {
    MacSpeakerMenu(root: root, player: player, memo: memo)
    continueButton
    copyControl
    retryControl
    MacRecordingButton(root: root, player: player, memo: memo)
    detailsButton
  }

  @ViewBuilder var flags: some View {
    let actions = MacMemoActions(root: root, model: root.windowHistory)
    Button(
      flagged.favorite
        ? String(localized: "Unfavorite", comment: "Context menu")
        : String(localized: "Favorite", comment: "Context menu"),
      systemImage: flagged.favorite ? "star.fill" : "star"
    ) { actions.toggleFavorite(flagged) }
    .macToolbarInk()
    .help((flagged.favorite ? MacMemoControl.unfavorite : .favorite).help)
    Button(
      flagged.archived
        ? String(localized: "Unarchive", comment: "Context menu")
        : String(localized: "Archive", comment: "Context menu"),
      systemImage: flagged.archived ? "tray.and.arrow.up" : "archivebox"
    ) { actions.toggleArchived(flagged) }
    .macToolbarInk()
    .help((flagged.archived ? MacMemoControl.unarchive : .archive).help)
    if flagged.state.isDeletable {
      Button(String(localized: "Delete", comment: "Context menu"), systemImage: "trash") {
        actions.delete(flagged, opened: model.memoID)
      }
      .macToolbarInk()
      .help(MacMemoControl.delete.help)
      .disabled(root.deletingIDs.contains(flagged.id))
    }
  }

  private var detailsButton: some View {
    Button(
      String(localized: "Details", comment: "Detail toolbar: opens the memo's details"), systemImage: "info.circle"
    ) { model.isShowingDetails.toggle() }
    .macToolbarInk()
    .help(MacMemoControl.details.help)
    .popover(isPresented: Bindable(model).isShowingDetails, arrowEdge: .bottom) {
      MacMemoDetailsPopover(root: root, model: model)
    }
    .accessibilityIdentifier("mac.detail.details")
  }

  /// Records another part of this transcript: a Transcribe take bound to its first part, stopped by the toolbar's Stop like any take.
  @ViewBuilder private var continueButton: some View {
    if let target = model.continuationTarget, !root.recording.isRecording {
      Button(
        String(localized: "Continue recording", comment: "Detail toolbar: records another part of this transcript"),
        systemImage: "text.alignleft"
      ) { root.recording.toggle(mode: .transcribe, threadID: target) }
      .macToolbarInk()
      .help(MacMemoControl.continueRecording.help)
      .accessibilityIdentifier("mac.detail.continue")
    }
  }

  /// One thing to copy is a button that copies at once; a menu only when there are two (the transcript and the reply).
  @ViewBuilder private var copyControl: some View {
    let targets = model.copyTargets
    if targets.count == 1, let target = targets.first {
      Button {
        model.copy(target)
      } label: {
        copyLabel
      }
      .macToolbarInk()
      .help((target == .transcript ? MacMemoControl.copyTranscriptNow : .copyReplyNow).help)
      .accessibilityIdentifier("mac.detail.copy")
    } else if targets.count > 1 {
      Menu {
        Button(String(localized: "Copy transcript", comment: "Detail toolbar menu")) { model.copy(.transcript) }
          .help(MacMemoControl.copyTranscript.help)
        Button(String(localized: "Copy reply", comment: "Detail toolbar menu")) { model.copy(.reply) }
          .help(MacMemoControl.copyReply.help)
      } label: {
        copyLabel
      }
      .menuIndicator(.hidden)
      .macToolbarInk()
      .help(MacMemoControl.copyMenu.help)
      .accessibilityIdentifier("mac.detail.copy")
    }
  }

  private var copyLabel: some View {
    Label(
      model.copied == nil
        ? String(localized: "Copy", comment: "Detail: copies the section as plain text")
        : String(localized: "Copied", comment: "Detail: confirmation after Copy"),
      systemImage: model.copied == nil ? "doc.on.doc" : "checkmark")
  }

  @ViewBuilder private var retryControl: some View {
    let steps = model.retrySteps
    if steps.count == 1, let step = steps.first {
      Button(
        String(localized: "Retry", comment: "Detail toolbar: retries a failed step"), systemImage: "arrow.clockwise"
      ) { Task { await model.retry(from: step) } }
      .macToolbarInk()
      .help(MacMemoControl.retry(from: step.title))
      .disabled(model.isRetrying)
      .accessibilityIdentifier("mac.detail.retry")
    } else if steps.count > 1 {
      Menu {
        ForEach(steps, id: \.self) { step in
          Button(String(localized: "Retry from \(step.title)", comment: "Button on the step a memo failed at")) {
            Task { await model.retry(from: step) }
          }
        }
      } label: {
        Label(
          String(localized: "Retry", comment: "Detail toolbar: retries a failed step"), systemImage: "arrow.clockwise")
      }
      .menuIndicator(.hidden)
      .macToolbarInk()
      .help(MacMemoControl.retryMenu.help)
      .disabled(model.isRetrying)
      .accessibilityIdentifier("mac.detail.retry")
    }
  }
}
