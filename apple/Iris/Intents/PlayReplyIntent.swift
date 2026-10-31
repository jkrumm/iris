import AppIntents

/// What the Play intent calls into. The app registers its composition root at launch; the intent file is compiled into the
/// widget extension too (the Live Activity's `Button(intent:)` names the type), where no handler exists.
@MainActor
protocol PlaybackIntentHandler: AnyObject {
  /// Speaks the reply of the memo through the app's shared player: the server's speech variant, downloaded with the
  /// device token. Throws when the memo has no reply to speak.
  func playReply(memoID: String) async throws
}

@MainActor
enum PlaybackIntents {
  static var handler: (any PlaybackIntentHandler)?
}

enum PlayReplyError: Error, CustomLocalizedStringResourceConvertible {
  case appNotReady
  case noReply
  case busy

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .appNotReady: "Iris is not ready to play yet."
    case .noReply: "This memo has no reply to play."
    case .busy: "Another reply is still loading. Try again in a moment."
    }
  }
}

/// Speaks a finished memo's reply: the Play action of the memo detail, the done Live Activity, a Shortcut. An
/// `AudioPlaybackIntent` runs in the app process, so the player and its session live there. Whether the system lets a
/// suspended app start playback from the Live Activity is spike S3 (device checklist); the fallback is opening the app.
struct PlayReplyIntent: AudioPlaybackIntent {
  static let title: LocalizedStringResource = "Play reply"
  static let description = IntentDescription("Speak the reply of a memo.")
  static let isDiscoverable = false

  @Parameter(title: "Memo")
  var memoID: String

  init() {}

  init(memoID: String) {
    self.memoID = memoID
  }

  @MainActor
  func perform() async throws -> some IntentResult {
    let memoID = memoID
    try await IntentEvents.run(
      self, named: "PlayReplyIntent", handlerPresent: PlaybackIntents.handler != nil, memoID: memoID
    ) {
      guard let handler = PlaybackIntents.handler else { throw PlayReplyError.appNotReady }
      try await handler.playReply(memoID: memoID)
    }
    return .result()
  }
}
