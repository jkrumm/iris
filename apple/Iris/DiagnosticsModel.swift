import Foundation
import IrisCore
import Observation

/// Settings → Diagnostics: pick a memo (the newest by default) and copy its id, the handle for debugging; the trace
/// id is the same id without the dashes. ``isCopied`` stays up until the view calls ``clearCopied()``.
@Observable
final class DiagnosticsModel {
  /// How many recent memos the picker offers.
  static let pickerSize = 10

  var selectedID: String? {
    didSet { if selectedID != oldValue { isCopied = false } }
  }
  private(set) var isCopied = false
  /// Bumped on every copy, so a second copy restarts the view's confirmation timer.
  private(set) var copyCount = 0

  private let pasteboard: any Pasteboard

  init(pasteboard: any Pasteboard) {
    self.pasteboard = pasteboard
  }

  /// The newest memos, newest first.
  func recent(_ memos: [Memo]) -> [Memo] {
    Array(memos.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }.prefix(Self.pickerSize))
  }

  /// The chosen memo while it is still in the list, else the newest.
  func selectedMemo(in memos: [Memo]) -> Memo? {
    let recent = recent(memos)
    return recent.first { $0.id == selectedID } ?? recent.first
  }

  func copyID(from memos: [Memo]) {
    guard let memo = selectedMemo(in: memos) else { return }
    pasteboard.copy(memo.id)
    isCopied = true
    copyCount += 1
  }

  func clearCopied() {
    isCopied = false
  }
}
