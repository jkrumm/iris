import AppIntents

/// The icon controls of the Live Activity and the Dynamic Island. A `LiveActivityIntent` runs in the app's process (the
/// system wakes it), so it reaches the same take the app's own screens control, through the handler the composition root
/// registered. Compiled into the widget extension too: its `Button(intent:)` names the types.
struct StopMemoIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Stop recording"
  static let isDiscoverable = false

  @MainActor
  func perform() async throws -> some IntentResult {
    try await CaptureIntents.run(self, named: "StopMemoIntent") { try await $0.endTake() }
    return .result()
  }
}

struct PauseMemoIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Pause or resume recording"
  static let isDiscoverable = false

  @MainActor
  func perform() async throws -> some IntentResult {
    try await CaptureIntents.run(self, named: "PauseMemoIntent") { await $0.toggleTakePause() }
    return .result()
  }
}

struct SwitchInputIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Switch microphone"
  static let isDiscoverable = false

  @MainActor
  func perform() async throws -> some IntentResult {
    try await CaptureIntents.run(self, named: "SwitchInputIntent") { try await $0.switchTakeInput() }
    return .result()
  }
}
