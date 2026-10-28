import Foundation

/// The banner at the bottom of History: the undo of a delete, the reason an action was rolled back, or a note.
struct HistoryToast: Identifiable, Hashable {
  enum Kind: Hashable {
    case undoDelete(memoID: String)
    case error
    /// Plain information, no action: a memo was queued instead of sent.
    case info
  }

  let id = UUID()
  let kind: Kind
  let message: String
}

extension HistoryToast.Kind {
  var isUndo: Bool {
    if case .undoDelete = self { true } else { false }
  }
}
