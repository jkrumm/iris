#if os(iOS)
  import Foundation
  import SnapshotTesting
  import SwiftUI
  import UIKit

  @testable import IrisUI

  /// Shared by the component snapshot suites. References come from one pinned simulator (iPhone 17, iOS 27.0);
  /// record with `RECORD=1` (via xcodebuild: `TEST_RUNNER_RECORD=1`).
  enum SnapshotSupport {
    static let record: SnapshotTestingConfiguration.Record? =
      ProcessInfo.processInfo.environment["RECORD"] == "1" ? .all : nil

    private static func traits(_ style: UIUserInterfaceStyle) -> UITraitCollection {
      UITraitCollection(traitsFrom: [
        UITraitCollection(userInterfaceStyle: style),
        UITraitCollection(displayScale: 3),
        UITraitCollection(preferredContentSizeCategory: .large),
      ])
    }

    /// Asserts `view` on the app background in light and dark, as `<test>.light` and `<test>.dark`.
    @MainActor
    static func assertLightAndDark<Content: View>(
      _ view: Content, width: CGFloat, height: CGFloat,
      fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function,
      line: UInt = #line, column: UInt = #column
    ) {
      for (scheme, style) in [(ColorScheme.light, UIUserInterfaceStyle.light), (.dark, .dark)] {
        let framed =
          view
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Theme.Surface.background)
          .environment(\.colorScheme, scheme)
        assertSnapshot(
          of: framed, as: .image(layout: .fixed(width: width, height: height), traits: traits(style)),
          named: scheme == .dark ? "dark" : "light",
          fileID: fileID, file: file, testName: testName, line: line, column: column)
      }
    }
  }
#endif
