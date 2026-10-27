import AppIntents
import SwiftUI
import WidgetKit

/// Placeholder action. The real `StartMemoIntent: AudioRecordingIntent` replaces it in R1.
struct RecordPlaceholderIntent: AppIntent {
  static let title: LocalizedStringResource = "Record with Iris"

  func perform() async throws -> some IntentResult {
    .result()
  }
}

struct RecordControl: ControlWidget {
  static let kind = "com.jkrumm.iris.widgets.record"

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: Self.kind) {
      ControlWidgetButton(action: RecordPlaceholderIntent()) {
        Label(String(localized: "Record", comment: "Control label"), systemImage: "mic.fill")
      }
    }
    .displayName("Record with Iris")
    .description("Start a voice memo.")
  }
}
