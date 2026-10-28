import Foundation

/// The banner at the bottom of History: the undo of a delete, or the reason an action was rolled back.
struct HistoryToast: Identifiable, Hashable {
  enum Kind: Hashable {
    case undoDelete(memoID: String)
    case error
  }

  let id = UUID()
  let kind: Kind
  let message: String
}
