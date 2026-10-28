import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center / Lock Screen button: it runs `StartMemoIntent` (shared with the app, which performs it).
struct RecordControl: ControlWidget {
  static let kind = "com.jkrumm.iris.widgets.record"

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: Self.kind) {
      ControlWidgetButton(action: StartMemoIntent()) {
        Label(String(localized: "Record", comment: "Control label"), systemImage: "mic.fill")
      }
    }
    .displayName("Record with Iris")
    .description("Start a voice memo.")
  }
}
