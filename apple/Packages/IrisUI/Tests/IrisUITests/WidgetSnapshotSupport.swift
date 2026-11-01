#if os(iOS)
  import SnapshotTesting
  import SwiftUI
  import UIKit

  @testable import IrisUI

  /// Frames for the widget snapshots. The system draws the real container, its corner radius, the wallpaper and the vibrant
  /// recoloring; these show what the widget puts into it. Sizes are the iPhone 16/17 Pro widget sizes in points (HIG,
  /// "Widgets": Home Screen 170 × 170 and 364 × 170, Lock Screen 76 × 76, 172 × 76 and 257 × 26).
  enum WidgetSnapshotSupport {
    static func size(_ family: IrisWidgetFamily) -> CGSize {
      switch family {
      case .systemSmall: CGSize(width: 170, height: 170)
      case .systemMedium: CGSize(width: 364, height: 170)
      case .accessoryCircular: CGSize(width: 76, height: 76)
      case .accessoryRectangular: CGSize(width: 172, height: 76)
      case .accessoryInline: CGSize(width: 257, height: 26)
      }
    }

    /// The margin around a drawn widget.
    private static let canvas: CGFloat = 12
    /// The system's default content margin inside a Home Screen widget.
    private static let contentMargin: CGFloat = 16

    private static func traits(_ style: UIUserInterfaceStyle) -> UITraitCollection {
      UITraitCollection(traitsFrom: [
        UITraitCollection(userInterfaceStyle: style),
        UITraitCollection(displayScale: 3),
        UITraitCollection(preferredContentSizeCategory: .large),
      ])
    }

    /// A Home Screen widget on its container background, light and dark: `<name>.light`, `<name>.dark`.
    @MainActor
    static func assertHome<Content: View>(
      _ content: Content, family: IrisWidgetFamily, name: String, locale: String = "en",
      fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function,
      line: UInt = #line, column: UInt = #column
    ) {
      let size = size(family)
      for (scheme, style) in [(ColorScheme.light, UIUserInterfaceStyle.light), (.dark, .dark)] {
        let framed =
          content
          .padding(contentMargin)
          .frame(width: size.width, height: size.height)
          .background(Theme.Surface.panel, in: .rect(cornerRadius: 22))
          .padding(canvas)
          .background(Color.gray.opacity(0.35))
          .environment(\.colorScheme, scheme)
          .environment(\.locale, Locale(identifier: locale))
        assertSnapshot(
          of: framed,
          as: .image(
            layout: .fixed(width: size.width + 2 * canvas, height: size.height + 2 * canvas), traits: traits(style)),
          named: "\(name).\(scheme == .dark ? "dark" : "light")",
          fileID: fileID, file: file, testName: testName, line: line, column: column)
      }
    }

    /// A widget with no container background on black (StandBy, Lock Screen): dark only, white ink.
    @MainActor
    static func assertBare<Content: View>(
      _ content: Content, family: IrisWidgetFamily, name: String, wallpaper: Bool = true, locale: String = "en",
      fileID: StaticString = #fileID, file: StaticString = #filePath, testName: String = #function,
      line: UInt = #line, column: UInt = #column
    ) {
      let size = size(family)
      let inset = family.isAccessory ? 0 : contentMargin
      let background: AnyShapeStyle =
        wallpaper
        ? AnyShapeStyle(LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom))
        : AnyShapeStyle(Color.black)
      let framed =
        content
        .padding(inset)
        .frame(width: size.width, height: size.height)
        .foregroundStyle(.white)
        .padding(canvas)
        .background(background)
        .environment(\.colorScheme, .dark)
        .environment(\.locale, Locale(identifier: locale))
      assertSnapshot(
        of: framed,
        as: .image(
          layout: .fixed(width: size.width + 2 * canvas, height: size.height + 2 * canvas), traits: traits(.dark)),
        named: name,
        fileID: fileID, file: file, testName: testName, line: line, column: column)
    }
  }

  /// Fake snapshots for the widget tests: one per state the last-memo widget has.
  enum WidgetSamples {
    static func line(_ phase: LastMemoSnapshot.Phase, headline: String? = nil) -> LastMemoWidgetContent {
      .memo(.init(phase: phase, routeChip: "Hermes", headline: headline, age: .text("3 min")))
    }

    static let states: [(name: String, content: LastMemoWidgetContent)] = [
      ("no-data", .noData),
      ("idle", .idle),
      ("processing", line(.processing)),
      ("done", line(.done, headline: "Wochenplan abgestimmt, Release am Donnerstag")),
      ("needs-route", line(.needsRoute, headline: "Router bestellen und Netzwerkplan prüfen")),
      ("failed", line(.failed)),
    ]
  }
#endif
