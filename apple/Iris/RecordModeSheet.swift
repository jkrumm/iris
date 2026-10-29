import IrisCore
import IrisUI
import SwiftUI

/// What a long press on the record control opens: the same mode chips as the composer, a line on what the mode does, and
/// Start. A plain tap on the control still records in Auto at once.
struct RecordModeSheet: View {
  let model: TakeModel
  @State private var mode = MemoMode.auto
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
        ModePicker(modes: MemoMode.voiceModes, selection: $mode)
          .accessibilityIdentifier("record.modes")
        Text(verbatim: mode.summary)
          .themeFont(.footnote)
          .foregroundStyle(Theme.Ink.muted)
          .accessibilityIdentifier("record.mode.summary")
        Spacer(minLength: 0)
        Button {
          dismiss()
          Task { await model.start(mode: mode) }
        } label: {
          Label(
            String(localized: "Start recording", comment: "Starts a take in the chosen mode"), systemImage: "mic.fill"
          )
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!model.canStart)
        .accessibilityIdentifier("record.mode.start")
      }
      .padding(Theme.Spacing.lg)
      .background(Theme.Surface.background)
      .navigationTitle(String(localized: "Record as", comment: "Mode picker title for a voice take"))
      .navigationBarTitleDisplayMode(.inline)
    }
    .accessibilityIdentifier("record.modeSheet")
  }
}
