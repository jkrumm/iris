#if os(iOS)
  import SnapshotTesting
  import SwiftUI
  import Testing

  @testable import IrisUI

  @MainActor
  @Suite(.snapshots(record: SnapshotSupport.record))
  struct PrimaryButtonSnapshotTests {
    private func buttons(isEnabled: Bool) -> some View {
      VStack(spacing: Theme.Spacing.lg) {
        Button {
        } label: {
          Label("Start recording", systemImage: "mic.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.primary)
        .controlSize(.large)
        Button {
        } label: {
          Label("Send", systemImage: "arrow.up")
        }
        .buttonStyle(.primary)
      }
      .disabled(!isEnabled)
      .padding(Theme.Spacing.lg)
    }

    @Test("the primary button is the accent fill with a white label, in light and dark", .tags(.snapshot))
    func enabled() {
      SnapshotSupport.assertLightAndDark(buttons(isEnabled: true), width: 390, height: 150)
    }

    @Test("a disabled primary button is a quiet panel with a muted label, never a washed-out accent", .tags(.snapshot))
    func disabled() {
      SnapshotSupport.assertLightAndDark(buttons(isEnabled: false), width: 390, height: 150)
    }
  }
#endif
