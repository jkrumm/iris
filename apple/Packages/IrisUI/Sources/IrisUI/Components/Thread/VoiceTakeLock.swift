/// Whether the voice take of ``ThreadReplyBar`` is a locked recording (tap to start, send button to end) rather than a hold.
///
/// The lock button only asks for a lock; the take is locked once the app reports it running (`holdStartedAt` set). A take that
/// fails to start never reports, so the request would otherwise outlive it and lock the next, unrelated take: any other way of
/// beginning a take drops it first.
struct VoiceTakeLock: Equatable {
  private var isRequested = false
  private(set) var isLocked = false

  /// The lock button was tapped; the take is about to begin.
  mutating func request() {
    isRequested = true
  }

  /// A take begins by holding or by the VoiceOver action: never locked.
  mutating func beginUnlocked() {
    isRequested = false
    isLocked = false
  }

  /// The app reported whether a take is running.
  mutating func takeChanged(isRecording: Bool) {
    isLocked = isRecording && isRequested
    isRequested = false
  }
}
