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
  /// Whether a take holds the microphone, asked of the capture session itself (it also knows a thread's hold-to-talk). Bound
  /// by the composition root; unbound (tests, previews) nothing is ever blocked.
  private var captureIsOpen: (() async -> Bool)?
  /// The same from what the screens already know, for the starts that cannot wait for an answer (the recording's play button).
  private var captureIsOpenNow: (() -> Bool)?
  /// Takes between `willOpenTake()` and `didOpenTake()`: the session has not published its state yet, but the microphone is
  /// about to open.
  private var openingTakes = 0
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

  func bindCapture(isOpen: @escaping () async -> Bool, isOpenNow: @escaping () -> Bool) {
    captureIsOpen = isOpen
    captureIsOpenNow = isOpenNow
  }

  /// A take is about to open the microphone, or has one open: nothing may start playing. Every playback start asks, and asks
  /// again after whatever it waited for (a memo fetched, a speech downloaded), so a start that began before the take cannot
  /// land inside it.
  var isCaptureBusyNow: Bool { openingTakes > 0 || captureIsOpenNow?() == true }

  private func captureIsBusy() async -> Bool {
    if openingTakes > 0 { return true }
    return await captureIsOpen?() == true
  }

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
      if !player.isPlaying {
        guard !(await captureIsBusy()) else { return }
        pauseRecording?()
      }
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
    guard !player.isLoading, let request = source.speech(for: memo), !(await captureIsBusy()) else { return false }
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
    // A take may have opened while the speech downloaded (or the memo was fetched before it): it has priority.
    guard !(await captureIsBusy()), attempt == mine else { return false }
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

  /// A take is starting (``willOpenTake()`` pairs it with ``didOpenTake()``): recording takes priority, so the reply (a download still under way included) and the open detail's
  /// recording stop at once, and the microphone never hears either. Nothing resumes by itself afterwards.
  func pauseForTake() {
    pause()
    pauseRecording?()
  }

  /// A take is about to open the microphone: playback stops and nothing starts until ``didOpenTake()`` and the session says
  /// the take is over. Call right before the capture session opens.
  func willOpenTake() {
    openingTakes += 1
    pauseForTake()
  }

  /// The session answered the start (the take is open, or failed to open).
  func didOpenTake() {
    openingTakes = max(0, openingTakes - 1)
  }

  /// Stops and releases the player, for the memo it speaks (`id`), or whichever when `id` is nil.
  func stop(memoID id: String? = nil) {
    guard id == nil || id == memoID else { return }
    attempt += 1
    player.teardown()
    memoID = nil
  }
}
