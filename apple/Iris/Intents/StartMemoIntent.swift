import AppIntents

/// What the start intent calls into. The app registers its composition root at launch; the intent file is compiled into
/// the widget extension too (the Control names the type), where no handler exists and `perform()` is never the one that runs.
@MainActor
protocol CaptureIntentHandler: AnyObject {
  /// Starts a take in `auto` mode and the Live Activity that goes with it (Apple stops a background recording that has none).
  func startMemo() async throws
  /// Ends the running take and sends it (the Live Activity's Stop). Nothing running is not an error.
  func endTake() async throws
  /// Pauses the running take, or resumes a paused one (the Live Activity's pause button).
  func toggleTakePause() async
  /// Moves the running take to the next available microphone (the Live Activity's mic-swap button).
  func switchTakeInput() async throws
}

@MainActor
enum CaptureIntents {
  static var handler: (any CaptureIntentHandler)?
}

enum StartMemoError: Error, CustomLocalizedStringResourceConvertible {
  case appNotReady
  case notConfigured
  case microphoneDenied
  case queueUnavailable

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .appNotReady: "Iris is not ready to record yet."
    case .notConfigured: "Connect Iris to your server in Settings first."
    case .microphoneDenied: "Iris needs microphone access to record."
    case .queueUnavailable: "Iris cannot open its outbox right now, so it cannot record."
    }
  }
}

/// Starts a voice memo from the Control, Siri or the Shortcuts app. An `AudioRecordingIntent` runs in the app process, so
/// the engine can start there; the Live Activity request is part of `startMemo()`.
struct StartMemoIntent: AudioRecordingIntent {
  static let title: LocalizedStringResource = "Record with Iris"
  static let description = IntentDescription("Start a voice memo.")

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let handler = CaptureIntents.handler else { throw StartMemoError.appNotReady }
    try await handler.startMemo()
    return .result()
  }
}
