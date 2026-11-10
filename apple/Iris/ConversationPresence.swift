import Observation

/// The conversation on screen right now, for the foreground notification decision (a banner for the conversation you are
/// reading is noise) and, later, for the voice reply. The thread screen sets it on appear and clears it on disappear.
@MainActor
@Observable
final class ConversationPresence {
  struct Current: Equatable, Sendable {
    let anchorID: String
    let threadID: String?
    let memoIDs: Set<String>
  }

  /// `nil` while no conversation is shown.
  private(set) var current: Current?

  /// Shown, or its thread/memos changed (a follow-up joined the conversation).
  func show(anchorID: String, threadID: String?, memoIDs: [String]) {
    current = Current(anchorID: anchorID, threadID: threadID, memoIDs: Set(memoIDs + [anchorID]))
  }

  func hide(anchorID: String) {
    guard current?.anchorID == anchorID else { return }
    current = nil
  }
}
