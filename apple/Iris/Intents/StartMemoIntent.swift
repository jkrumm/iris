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

  /// The handler, waiting a moment for it: an intent that launches the app cold is performed while the composition root is
  /// still being built. `nil` when it never shows up (the extension, which has none), so the caller can say so.
  static func readyHandler(timeout: Duration = .seconds(3)) async -> (any CaptureIntentHandler)? {
    let deadline = ContinuousClock.now + timeout
    while handler == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    return handler
  }
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

/// Starts a voice memo from the Control, Siri or the Shortcuts app. A control's intent runs in the widget extension unless
/// it conforms to `LiveActivityIntent` (or `AudioPlaybackIntent`, `openAppWhenRun`, ...): then the system launches the app
/// process in the background and performs it there, where the handler exists and a Live Activity may be requested without
/// the app being in the foreground. `AudioRecordingIntent` alone does neither (it only shows the recording indicator and
/// obliges the Live Activity), so the Record control did nothing: `perform()` ran in `IrisWidgets`, found no handler and threw.
/// The Live Activity request is part of `startMemo()`.
struct StartMemoIntent: AudioRecordingIntent, LiveActivityIntent {
  static let title: LocalizedStringResource = "Record with Iris"
  static let description = IntentDescription("Start a voice memo.")

  @MainActor
  func perform() async throws -> some IntentResult {
    try await IntentEvents.run(self, named: "StartMemoIntent", handlerPresent: CaptureIntents.handler != nil) {
      guard let handler = CaptureIntents.handler else { throw StartMemoError.appNotReady }
      try await handler.startMemo()
    }
    return .result()
  }
}

/// The one thing the Record control opens.
enum RecorderDestination: String, AppEnum {
  case recorder

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Recorder")
  static let caseDisplayRepresentations: [RecorderDestination: DisplayRepresentation] = [
    .recorder: DisplayRepresentation(title: "Recorder")
  ]
}

/// What the Record control runs. WidgetKit performs a control's intent in the widget extension, in the background, and the
/// extension cannot record; only an `OpenIntent` that is in both targets makes the system bring the app to the foreground
/// and perform the intent there. On the Lock Screen a button is inactive until the device is unlocked, so the policy asks for
/// that: the press shows the unlock prompt, then the app opens and the take starts (a foreground start can activate the
/// audio session and request the Live Activity; the `LiveActivityIntent` start of the earlier build ran in the background,
/// did nothing on the Lock Screen and left no trace). A start that fails is shown in the app (`TakeModel.failure`) and
/// thrown back to the system.
struct OpenRecorderIntent: OpenIntent {
  static let title: LocalizedStringResource = "Record with Iris"
  static let description = IntentDescription("Open Iris and start a voice memo.")
  static let isDiscoverable = false
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  @Parameter(title: "Destination")
  var target: RecorderDestination

  init() { target = .recorder }

  @MainActor
  func perform() async throws -> some IntentResult {
    let handler = await CaptureIntents.readyHandler()
    try await IntentEvents.run(self, named: "OpenRecorderIntent", handlerPresent: handler != nil) {
      guard let handler else { throw StartMemoError.appNotReady }
      try await handler.startMemo()
    }
    return .result()
  }
}
