import IrisCore
import IrisUI
import SwiftUI

/// The History swipes (round 2). Native `swipeActions`: the first button of an edge is the full swipe, the second
/// one is revealed by a partial swipe. Right: done, favorite. Left: archive, delete (settled memos only).
struct MemoSwipeActions: ViewModifier {
  let memo: Memo
  let model: HistoryModel

  func body(content: Content) -> some View {
    content
      .swipeActions(edge: .leading, allowsFullSwipe: true) {
        Button(doneTitle, systemImage: "checkmark") {
          Task { await model.toggleDone(memo) }
        }
        .tint(Theme.Status.good)
        .accessibilityIdentifier("history.swipe.done")
        Button(favoriteTitle, systemImage: memo.favorite ? "star.slash" : "star") {
          Task { await model.toggleFavorite(memo) }
        }
        .tint(Theme.Status.warn)
        .accessibilityIdentifier("history.swipe.favorite")
      }
      .swipeActions(edge: .trailing, allowsFullSwipe: true) {
        Button(archiveTitle, systemImage: memo.archived ? "tray.and.arrow.up" : "archivebox") {
          Task { await model.toggleArchived(memo) }
        }
        .tint(Theme.Status.neutral)
        .accessibilityIdentifier("history.swipe.archive")
        if memo.state.isDeletable {
          Button(String(localized: "Delete", comment: "Swipe action"), systemImage: "trash", role: .destructive) {
            Task { await model.delete(memo) }
          }
          .accessibilityIdentifier("history.swipe.delete")
        }
      }
  }

  private var doneTitle: String {
    memo.done
      ? String(localized: "Not done", comment: "Swipe action") : String(localized: "Done", comment: "Swipe action")
  }

  private var favoriteTitle: String {
    memo.favorite
      ? String(localized: "Unfavorite", comment: "Swipe action")
      : String(localized: "Favorite", comment: "Swipe action")
  }

  private var archiveTitle: String {
    memo.archived
      ? String(localized: "Unarchive", comment: "Swipe action") : String(localized: "Archive", comment: "Swipe action")
  }
}
