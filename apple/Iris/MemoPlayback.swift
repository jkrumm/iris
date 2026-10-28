import Observation

/// The two voices of the detail screen, the recording and the spoken reply, and the rule that only one of them
/// plays. Every start goes through here, so no call site has to remember to pause the other.
@Observable
final class MemoPlayback {
  let recording: MemoPlayer
  let reply = MemoPlayer()

  init(recordingDuration: Double = 0) {
    recording = MemoPlayer(duration: recordingDuration)
  }

  func toggleRecording() {
    reply.pause()
    recording.toggle()
  }

  /// `request` is loaded the first time the reply plays; a tap while it is still loading is ignored.
  func toggleReply(loading request: @autoclosure () -> MediaRequest?) async {
    guard !reply.isLoading else { return }
    if !reply.isLoaded { await reply.load(request()) }
    recording.pause()
    reply.toggle()
  }

  func pauseAll() {
    recording.pause()
    reply.pause()
  }

  /// Stops both and releases their players; the screen calls it when it goes away.
  func teardown() {
    recording.teardown()
    reply.teardown()
  }
}
