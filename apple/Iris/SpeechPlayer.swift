import IrisCore
import Observation

/// The one player of spoken replies in the app: the detail screen's Play, `PlayReplyIntent` and the spoken-replies setting
/// all speak through it, so two replies never talk over each other and whichever starts last wins. It remembers which memo
/// it was loaded for, because one player serves every memo. The speech is the server's speech variant
/// (`GET /v1/memos/:id/speech`), downloaded with the device token by ``MediaDownloader`` and played from the file.
@Observable
final class SpeechPlayer {
  let player: MemoPlayer
  /// The memo whose reply the player holds (or is loading).
  private(set) var memoID: String?
  /// Pauses the recording of the detail screen that is open, if any: bound by its ``MemoPlayback``, called right before a
  /// reply starts so a reply the user starts (Play, `PlayReplyIntent`) never plays over a recording. A spoken reply never
  /// gets here while the recording plays: ``SpokenReplies`` waits on ``isBusy``.
  private var pauseRecording: (() -> Void)?
  /// Whether that screen's recording is playing, for ``isBusy``.
  private var recordingIsPlaying: (() -> Bool)?
  private weak var recordingOwner: AnyObject?
  /// Bumped by every start, pause and stop; a download that finds it changed belongs to a start that was overtaken (the
  /// user paused, stopped, or started the recording, while the speech was downloading).
  private var attempt = 0

  init(player: MemoPlayer = MemoPlayer()) {
    self.player = player
  }

  func isPlaying(_ id: String) -> Bool { memoID == id && player.isPlaying }

  /// Something is audible or about to be: a reply loading or playing, or the open detail's recording playing. A reply that
  /// starts on its own (``SpokenReplies``) waits instead of interrupting it; a start the user asks for does not look at it.
  var isBusy: Bool { player.isLoading || player.isPlaying || recordingIsPlaying?() == true }

  /// `owner` is the screen whose recording `pause` stops before a reply starts; the last screen to bind wins.
  func bindRecording(owner: AnyObject, isPlaying: @escaping () -> Bool, pause: @escaping () -> Void) {
    recordingOwner = owner
    recordingIsPlaying = isPlaying
    pauseRecording = pause
  }

  /// Clears the hook only if `owner` still holds it, so a screen that goes away does not disconnect the one that replaced it.
  func unbindRecording(owner: AnyObject) {
    guard recordingOwner === owner else { return }
    recordingOwner = nil
    recordingIsPlaying = nil
    pauseRecording = nil
  }

  /// Plays the reply of `memo`, or pauses it when it is the one playing (and resumes it when paused). A tap while a reply is
  /// still loading is ignored.
  func toggle(_ memo: Memo, source: any MemoMediaSource) async {
    guard !player.isLoading else { return }
    if memoID == memo.id, player.isLoaded {
      if !player.isPlaying { pauseRecording?() }
      player.toggle()
      return
    }
    await play(memo, source: source)
  }

  /// Starts the reply of `memo` from the top, replacing whatever was speaking; true when it is playing. Nothing happens
  /// (false) when the memo has no speech or another reply is still loading. `shouldPlay` is asked again once the download is
  /// done, so a reply the caller no longer wants (the app went to the background meanwhile) stays silent.
  @discardableResult
  func play(_ memo: Memo, source: any MemoMediaSource, shouldPlay: () -> Bool = { true }) async -> Bool {
    guard !player.isLoading, let request = source.speech(for: memo) else { return false }
    attempt += 1
    let mine = attempt
    memoID = memo.id
    await player.load(request)
    // Overtaken (a pause, a stop or another start): whoever did that owns `memoID` now. A download that failed or was
    // cancelled leaves the player holding nothing, so it must not claim the memo either.
    guard attempt == mine, memoID == memo.id else { return false }
    guard player.isLoaded else {
      memoID = nil
      return false
    }
    guard shouldPlay() else { return false }
    pauseRecording?()
    player.seek(to: 0)
    player.play()
    return true
  }

  /// Pauses the reply, and cancels one that is still downloading.
  func pause() {
    attempt += 1
    player.pause()
  }

  /// Stops and releases the player, for the memo it speaks (`id`), or whichever when `id` is nil.
  func stop(memoID id: String? = nil) {
    guard id == nil || id == memoID else { return }
    attempt += 1
    player.teardown()
    memoID = nil
  }
}
