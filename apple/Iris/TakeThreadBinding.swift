import IrisCore

/// Whether a take started now continues the conversation on screen. A Hermes take started while a conversation with a known
/// thread is on top is its reply; everywhere else (History, Stats, Settings, a conversation whose thread is not known yet,
/// Transcribe, which the server refuses `threadId` for) it is a new memo.
nonisolated enum TakeThreadBinding {
  static func threadID(for mode: MemoMode, presence: ConversationPresence.Current?) -> String? {
    guard mode == .hermes else { return nil }
    return presence?.threadID
  }
}
