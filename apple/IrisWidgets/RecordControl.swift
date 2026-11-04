import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center / Lock Screen button: it runs `OpenRecorderIntent` (shared with the app, which opens and performs it, so the take starts in the foreground).
struct RecordControl: ControlWidget {
  static let kind = "com.jkrumm.iris.widgets.record"

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: Self.kind) {
      ControlWidgetButton(action: OpenRecorderIntent()) {
        Label(String(localized: "Record", comment: "Control label"), systemImage: "mic.fill")
      }
    }
    .displayName("Record with Iris")
    .description("Start a voice memo.")
  }
}

/// The second Control: `OpenTranscribeRecorderIntent` starts a take whose memo is only transcribed (same road as ``RecordControl``).
struct TranscribeControl: ControlWidget {
  static let kind = "com.jkrumm.iris.widgets.transcribe"

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: Self.kind) {
      ControlWidgetButton(action: OpenTranscribeRecorderIntent()) {
        Label(String(localized: "Transcribe", comment: "Control label"), systemImage: "text.alignleft")
      }
    }
    .displayName("Transcribe with Iris")
    .description("Start a voice memo that is only transcribed.")
  }
}
