import IrisCore
import IrisUI

/// How a conversation's entries become turns while a reply is still running, for the iPhone's `ThreadModel` and the Mac's
/// `MacMemoDetailModel`: a pending entry with live events is the tool list, then the streaming answer.
enum LiveConversation {
  /// The turns of `entries`. A memo that ended (result-ready or failed) loses its live turn; a pending entry with one becomes
  /// the streaming reply once there is a complete base, else the tool list. The streaming turn takes the id of the final reply
  /// (`<memo>.reply`), so the stored answer replaces it in place.
  static func turns(of entries: [ConversationEntry], live: inout LiveTurns) -> [ConversationTurn] {
    for entry in entries where entry.memo.state.isResultReady || entry.memo.state == .failed {
      live.drop(memoID: entry.memo.id)
    }
    return entries.map { liveTurn(for: $0, live: live) ?? ConversationTurn($0) }
  }

  private static func liveTurn(for entry: ConversationEntry, live: LiveTurns) -> ConversationTurn? {
    guard case .pending = entry.kind, let turn = live.turn(for: entry.memo.id) else { return nil }
    if !turn.shownText.isEmpty {
      return ConversationTurn(
        id: "\(entry.memo.id).reply", memoID: entry.memo.id, date: nil,
        content: .streaming(markdown: turn.shownText, activity: turn.currentTool.map(ToolActivityText.label(for:))))
    }
    guard !turn.tools.isEmpty else { return nil }
    let lines = turn.tools.enumerated().map {
      ActivityLine(id: $0.offset, label: ToolActivityText.label(for: $0.element))
    }
    return ConversationTurn(id: entry.id, memoID: entry.memo.id, date: nil, content: .working(lines))
  }
}
