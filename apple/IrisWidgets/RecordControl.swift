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
