#if os(iOS)
  import SnapshotTesting
  import SwiftUI
  import Testing

  @testable import IrisUI

  @MainActor
  @Suite(.snapshots(record: SnapshotSupport.record))
  struct SettingsSnapshotTests {
    @Test("the copy button before and after the copy", .tags(.snapshot))
    func copyButton() {
      let row = HStack(spacing: Theme.Spacing.md) {
        CopyButton(title: "Copy memo id", copiedTitle: "Copied", isCopied: false) {}
        CopyButton(title: "Copy memo id", copiedTitle: "Copied", isCopied: true) {}
      }
      .padding(Theme.Spacing.lg)
      SnapshotSupport.assertLightAndDark(row, width: 390, height: 72)
    }

    @Test("the memo id on its monospace field", .tags(.snapshot))
    func idField() {
      let field = IDValueField("0b6d1f4e-3a52-4c1d-9f0e-7a2c5d8e1b34")
        .padding(Theme.Spacing.lg)
      SnapshotSupport.assertLightAndDark(field, width: 390, height: 96)
    }

    @Test("queued outbox items in each state", .tags(.snapshot))
    func outboxRows() {
      let rows = VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
        OutboxItemRow(
          systemImage: "waveform", title: "Voice memo · 38 s", detail: "Recorded 9:20", status: .sending,
          statusText: "Sending")
        OutboxItemRow(
          systemImage: "text.bubble", title: "Which Postgres index fits…", detail: "Chat message", status: .waiting,
          statusText: "Waiting")
        OutboxItemRow(
          systemImage: "waveform", title: "Voice memo · 14 s", detail: "Recorded 8:02", status: .failed,
          statusText: "Retry in 40 s")
      }
      .padding(Theme.Spacing.lg)
      SnapshotSupport.assertLightAndDark(rows, width: 390, height: 190)
    }
  }
#endif
