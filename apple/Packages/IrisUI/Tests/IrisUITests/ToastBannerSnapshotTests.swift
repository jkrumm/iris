#if os(iOS)
  import SnapshotTesting
  import SwiftUI
  import Testing

  @testable import IrisUI

  @MainActor
  @Suite(.snapshots(record: SnapshotSupport.record))
  struct ToastBannerSnapshotTests {
    @Test("the undo toast", .tags(.snapshot))
    func undo() {
      let toast = ToastBanner(message: "Memo deleted", actionTitle: "Undo") {}
        .padding(Theme.Spacing.lg)
      SnapshotSupport.assertLightAndDark(toast, width: 390, height: 96)
    }

    @Test("the error toast has no action", .tags(.snapshot))
    func error() {
      let toast = ToastBanner(message: "Could not update the memo")
        .padding(Theme.Spacing.lg)
      SnapshotSupport.assertLightAndDark(toast, width: 390, height: 96)
    }
  }
#endif
