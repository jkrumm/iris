#if os(iOS)
  import Foundation
  import SnapshotTesting
  import SwiftUI
  import Testing
  import UIKit

  @testable import IrisUI

  /// Reference images in `__Snapshots__/` come from one pinned simulator (iPhone 17, iOS 27.0).
  /// Record with `RECORD=1` (via xcodebuild: `TEST_RUNNER_RECORD=1`).
  private let recordMode: SnapshotTestingConfiguration.Record? =
    ProcessInfo.processInfo.environment["RECORD"] == "1" ? .all : nil

  @MainActor
  @Suite(.snapshots(record: recordMode))
  struct KindChipSnapshotTests {
    private static func traits(_ style: UIUserInterfaceStyle) -> UITraitCollection {
      UITraitCollection(traitsFrom: [
        UITraitCollection(userInterfaceStyle: style),
        UITraitCollection(displayScale: 3),
        UITraitCollection(preferredContentSizeCategory: .large),
      ])
    }

    private func chip(_ scheme: ColorScheme) -> some View {
      KindChip(label: "Github issue", systemImage: "tag.fill")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Surface.background)
        .environment(\.colorScheme, scheme)
    }

    @Test("KindChip renders in light and dark", .tags(.snapshot))
    func kindChip() {
      for (scheme, style) in [(ColorScheme.light, UIUserInterfaceStyle.light), (.dark, .dark)] {
        assertSnapshot(
          of: chip(scheme),
          as: .image(
            layout: .fixed(width: 240, height: 96), traits: Self.traits(style)),
          named: scheme == .dark ? "dark" : "light")
      }
    }
  }

  extension Tag {
    @Tag static var snapshot: Self
  }
#endif
