import AppIntents

/// What the start intent calls into. The app registers its composition root at launch; the intent file is compiled into
/// the widget extension too (the Control names the type), where no handler exists and `perform()` is never the one that runs.
@MainActor
protocol CaptureIntentHandler: AnyObject {
  /// Starts a take in `hermes` mode and the Live Activity that goes with it (Apple stops a background recording that has none).
  func startMemo() async throws
  /// The Shortcuts / Siri start. With the app in the background the Live Activity is requested before the audio session is
  /// activated, and a refusal throws ``StartMemoError/backgroundStartRefused`` with nothing left behind; with the app active it is
  /// ``startMemo()``.
  func startMemoFromShortcut() async throws
  /// Starts a take in `transcribe` mode (only the transcript comes back) with its Live Activity: the Transcribe control.
  func startTranscribeMemo() async throws
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
  /// still being built. `nil` when it never shows up (the extension, which has none), so the caller can say so. Throws
  /// `CancellationError` as soon as the intent is cancelled, so a cancelled press can never go on to start a recording.
  static func readyHandler(timeout: Duration = .seconds(3)) async throws -> (any CaptureIntentHandler)? {
    try Task.checkCancellation()
    let deadline = ContinuousClock.now + timeout
    while handler == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    try Task.checkCancellation()
    return handler
  }

  /// Runs `body` as the named intent against the handler, waiting for it first. The wait is inside ``IntentEvents/run``, so a
  /// press whose root never shows up still logs `intent.perform` and `intent.result` (with `handler=false` and `appNotReady`):
  /// those lines are how a cold-start press is diagnosed. `handlerPresent` is whether the root was ready when the press came.
  static func run<Result>(
    _ intent: some AppIntent, named name: String, timeout: Duration = .seconds(3),
    _ body: (any CaptureIntentHandler) async throws -> Result
  ) async throws -> Result {
    try await IntentEvents.run(intent, named: name, handlerPresent: handler != nil) {
      guard let handler = try await readyHandler(timeout: timeout) else { throw StartMemoError.appNotReady }
      return try await body(handler)
    }
  }
}

enum StartMemoError: Error, CustomLocalizedStringResourceConvertible {
  case appNotReady
  case notConfigured
  case microphoneDenied
  case queueUnavailable
  /// A start from the background was refused (the Live Activity, the audio session or the engine); the foreground can still do it.
  case backgroundStartRefused
  /// The microphone would not start in the foreground either.
  case recordingFailed

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .appNotReady: "Iris is not ready to record yet."
    case .notConfigured: "Connect Iris to your server in Settings first."
    case .microphoneDenied: "Iris needs microphone access to record."
    case .queueUnavailable: "Iris cannot open its outbox right now, so it cannot record."
    case .backgroundStartRefused: "iOS did not let Iris start recording in the background. Open Iris and try again."
    case .recordingFailed: "Iris could not start the microphone."
    }
  }
}

/// Try the start in the background; if the system refused it, ask to continue in the foreground and start there. The intent
/// supplies the system's side as closures, so the decision runs in tests without an `AppIntent` runtime.
@MainActor
enum StartMemoFallback {
  static let foregroundDialog: LocalizedStringResource = "Iris needs to open to record."

  static func run(
    canContinueInForeground: () -> Bool,
    background: () async throws -> Void,
    continueInForeground: () async throws -> Void,
    foreground: () async throws -> Void,
    road: (StartRoad) -> Void
  ) async throws {
    do {
      try await background()
      road(.background)
    } catch StartMemoError.backgroundStartRefused {
      guard canContinueInForeground() else { throw StartMemoError.backgroundStartRefused }
      try await continueInForeground()
      try await foreground()
      road(.foregroundFallback)
    }
  }
}

/// Starts a voice memo from the Control, Siri or the Shortcuts app. A control's intent runs in the widget extension unless
/// it conforms to `LiveActivityIntent` (or `AudioPlaybackIntent`, `openAppWhenRun`, ...): then the system launches the app
/// process in the background and performs it there, where the handler exists and a Live Activity may be requested without
/// the app being in the foreground. `AudioRecordingIntent` alone does neither (it only shows the recording indicator and
/// obliges the Live Activity), so the Record control did nothing: `perform()` ran in `IrisWidgets`, found no handler and threw.
/// The Live Activity request is part of `startMemo()`.
///
/// With the app in the background the Live Activity is requested first and the session starts after it; when the system refuses
/// either, the intent continues in the foreground (`supportedModes`) and starts there. Built on the D1-3 failure, not yet
/// verified on a device.
struct StartMemoIntent: AudioRecordingIntent, LiveActivityIntent {
  static let title: LocalizedStringResource = "Record with Iris"
  static let description = IntentDescription("Start a voice memo.")
  static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

  @MainActor
  func perform() async throws -> some IntentResult {
    try await CaptureIntents.run(self, named: "StartMemoIntent") { handler in
      try await StartMemoFallback.run(
        canContinueInForeground: { systemContext.currentMode.canContinueInForeground },
        background: { try await handler.startMemoFromShortcut() },
        continueInForeground: {
          try await continueInForeground(IntentDialog(StartMemoFallback.foregroundDialog), alwaysConfirm: false)
        },
        foreground: { try await handler.startMemo() },
        road: { IntentEvents.road($0, intent: "StartMemoIntent") })
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

/// The one thing the Transcribe control opens. Its own type: every `OpenIntent` needs a target type no other one has.
enum TranscribeRecorderDestination: String, AppEnum {
  case recorder

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Transcribe recorder")
  static let caseDisplayRepresentations: [TranscribeRecorderDestination: DisplayRepresentation] = [
    .recorder: DisplayRepresentation(title: "Transcribe recorder")
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
    try await CaptureIntents.run(self, named: "OpenRecorderIntent") { try await $0.startMemo() }
    return .result()
  }
}

/// What the Transcribe control runs: the same road as ``OpenRecorderIntent`` (unlock, open the app, start in the foreground),
/// for a take whose memo is only transcribed. A second type, not a parameter, because a control's intent takes none.
struct OpenTranscribeRecorderIntent: OpenIntent {
  static let title: LocalizedStringResource = "Transcribe with Iris"
  static let description = IntentDescription("Open Iris and start a voice memo that is only transcribed.")
  static let isDiscoverable = false
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  @Parameter(title: "Destination")
  var target: TranscribeRecorderDestination

  init() { target = .recorder }

  @MainActor
  func perform() async throws -> some IntentResult {
    try await CaptureIntents.run(self, named: "OpenTranscribeRecorderIntent") { try await $0.startTranscribeMemo() }
    return .result()
  }
}
