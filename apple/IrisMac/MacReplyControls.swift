import IrisCore
import IrisUI

/// The inline reply players of the conversation, wired to the window's one MacAudioPlayer: the same controls the iPhone's thread
/// has, so a Mac answer plays, pauses, seeks and switches between the summary and the full reply in its own bubble. The toolbar's
/// speaker drives the same player, so the two never disagree about what plays.
@MainActor
enum MacReplyControls {
  /// - Parameters:
  ///   - source: The media routes (read at each tap, so a connection change is picked up).
  ///   - memo: A memo of the open conversation by id; nil for one it does not hold.
  static func make(
    player: MacAudioPlayer, source: @escaping () -> any MemoMediaSource, memo: @escaping (String) -> Memo?
  ) -> ReplyControls {
    ReplyControls(
      playback: { player.replyPlayback(for: $0) },
      canPlay: { id in memo(id).map { source().speech(for: $0) != nil } ?? false },
      onToggle: { id in
        guard let found = memo(id) else { return }
        // What the player holds for this memo pauses or resumes in its own form; nothing held starts the summary.
        let variant = player.replyVariant(of: id) ?? .summary
        player.togglePlayback(id, .reply(variant), request: source().speech(for: found, variant: variant))
      },
      onPlay: { id, choice in
        guard let found = memo(id) else { return }
        let variant = SpeechVariant(choice)
        player.togglePlayback(id, .reply(variant), request: source().speech(for: found, variant: variant))
      },
      onSeek: { id, seconds in
        guard player.isReplyCurrent(id) else { return }
        player.seek(to: seconds)
      })
  }
}

extension SpeechVariant {
  /// The form a player's menu entry asks for.
  init(_ choice: ReplyPlayChoice) {
    switch choice {
    case .summary: self = .summary
    case .full: self = .full
    }
  }
}
