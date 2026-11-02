import AppIntents

/// The icon controls of the Live Activity and the Dynamic Island. A `LiveActivityIntent` runs in the app's process (the
/// system wakes it), so it reaches the same take the app's own screens control, through the handler the composition root
/// registered. Compiled into the widget extension too: its `Button(intent:)` names the types.
struct StopMemoIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Stop recording"
  static let isDiscoverable = false

  @MainActor
  func perform() async throws -> some IntentResult {
    let handler = try await CaptureIntents.readyHandler()
    try await IntentEvents.run(self, named: "StopMemoIntent", handlerPresent: handler != nil) {
      guard let handler else { throw StartMemoError.appNotReady }
      try await handler.endTake()
    }
    return .result()
  }
}

struct PauseMemoIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Pause or resume recording"
  static let isDiscoverable = false

  @MainActor
  func perform() async throws -> some IntentResult {
    let handler = try await CaptureIntents.readyHandler()
    try await IntentEvents.run(self, named: "PauseMemoIntent", handlerPresent: handler != nil) {
      guard let handler else { throw StartMemoError.appNotReady }
      await handler.toggleTakePause()
    }
    return .result()
  }
}

struct SwitchInputIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Switch microphone"
  static let isDiscoverable = false

  @MainActor
  func perform() async throws -> some IntentResult {
    let handler = try await CaptureIntents.readyHandler()
    try await IntentEvents.run(self, named: "SwitchInputIntent", handlerPresent: handler != nil) {
      guard let handler else { throw StartMemoError.appNotReady }
      try await handler.switchTakeInput()
    }
    return .result()
  }
}
