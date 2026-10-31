import IrisCore
import Observation

/// The two voices of the detail screen, the recording and the spoken reply, and the rule that only one of them
/// plays. Every start goes through here, so no call site has to remember to pause the other. The reply is the app's
/// shared ``SpeechPlayer``: the recording belongs to this screen, the speech to the app.
@Observable
final class MemoPlayback {
  let recording: MemoPlayer
  let speech: SpeechPlayer
  private let memoID: String

  /// No side effects: SwiftUI builds the `@State` initial value on every `init` of the screen and keeps only the first. The
  /// screen calls ``attach()`` once it is on screen.
  init(memoID: String, recordingDuration: Double = 0, speech: SpeechPlayer) {
    recording = MemoPlayer(duration: recordingDuration)
    self.speech = speech
    self.memoID = memoID
  }

  /// Lets the shared player see this screen's recording (a spoken reply waits while it plays) and pause it for a reply the
  /// user starts elsewhere (`PlayReplyIntent`).
  func attach() {
    speech.bindRecording(
      owner: self, isPlaying: { [weak recording] in recording?.isPlaying == true },
      pause: { [weak recording] in recording?.pause() })
  }

  /// The reply of this screen's memo is speaking.
  var isReplyPlaying: Bool { speech.isPlaying(memoID) }

  func toggleRecording() {
    // Starting it while a take records would record it into the take; pausing it is always allowed.
    guard recording.isPlaying || !speech.captureActive() else { return }
    speech.pause()
    recording.toggle()
  }

  /// `memo`'s reply is loaded the first time it plays; a tap while it is still loading is ignored.
  func toggleReply(_ memo: Memo, source: any MemoMediaSource) async {
    recording.pause()
    await speech.toggle(memo, source: source)
  }

  func pauseAll() {
    recording.pause()
    speech.pause()
  }

  /// Stops the recording and this memo's reply and releases their players; the screen calls it when it goes away. A reply
  /// of another memo (a spoken reply that started meanwhile) keeps speaking.
  func teardown() {
    recording.teardown()
    speech.unbindRecording(owner: self)
    speech.stop(memoID: memoID)
  }
}
