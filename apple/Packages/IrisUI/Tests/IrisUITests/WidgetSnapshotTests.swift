#if os(iOS)
  import SnapshotTesting
  import SwiftUI
  import Testing

  @testable import IrisUI

  /// Every family and state of the two widgets on the pinned simulator. They check layout and content in a plain hosting
  /// controller; the system's container, wallpaper and vibrant compositing are device-only (`docs/spikes/device-checklist.md`).
  @MainActor
  @Suite(.snapshots(record: SnapshotSupport.record))
  struct WidgetSnapshotTests {
    private func lastMemo(
      _ content: LastMemoWidgetContent, _ family: IrisWidgetFamily, rendering: IrisWidgetRendering = .fullColor,
      background: Bool = true
    ) -> some View {
      LastMemoWidgetView(
        content: content,
        context: IrisWidgetContext(family: family, rendering: rendering, showsContainerBackground: background)
      ) { $0 }
    }

    private func record(_ family: IrisWidgetFamily, rendering: IrisWidgetRendering = .fullColor) -> some View {
      RecordWidgetView(context: IrisWidgetContext(family: family, rendering: rendering)) { $0 }
    }

    @Test("home screen small: last memo in every state", .tags(.snapshot))
    func lastMemoSmall() {
      for (name, content) in WidgetSamples.states {
        WidgetSnapshotSupport.assertHome(lastMemo(content, .systemSmall), family: .systemSmall, name: name)
      }
    }

    @Test("home screen medium: last memo and record button in every state", .tags(.snapshot))
    func lastMemoMedium() {
      for (name, content) in WidgetSamples.states {
        WidgetSnapshotSupport.assertHome(lastMemo(content, .systemMedium), family: .systemMedium, name: name)
      }
    }

    @Test("home screen small: record", .tags(.snapshot))
    func recordSmall() {
      WidgetSnapshotSupport.assertHome(record(.systemSmall), family: .systemSmall, name: "record")
    }

    @Test("lock screen rectangular: last memo in every state", .tags(.snapshot))
    func lastMemoRectangular() {
      for (name, content) in WidgetSamples.states {
        WidgetSnapshotSupport.assertBare(
          lastMemo(content, .accessoryRectangular, rendering: .vibrant, background: false),
          family: .accessoryRectangular, name: name)
      }
    }

    @Test("lock screen inline: last memo in every state", .tags(.snapshot))
    func lastMemoInline() {
      for (name, content) in WidgetSamples.states {
        WidgetSnapshotSupport.assertBare(
          lastMemo(content, .accessoryInline, rendering: .vibrant, background: false),
          family: .accessoryInline, name: name)
      }
    }

    @Test("lock screen circular: last memo state and record", .tags(.snapshot))
    func circular() {
      for (name, content) in WidgetSamples.states {
        WidgetSnapshotSupport.assertBare(
          lastMemo(content, .accessoryCircular, rendering: .vibrant, background: false),
          family: .accessoryCircular, name: "state-\(name)")
      }
      WidgetSnapshotSupport.assertBare(
        record(.accessoryCircular, rendering: .vibrant), family: .accessoryCircular, name: "record")
    }

    @Test("StandBy: the small widgets with the background removed", .tags(.snapshot))
    func standBy() {
      let done = WidgetSamples.line(.done, headline: "Wochenplan abgestimmt, Release am Donnerstag")
      WidgetSnapshotSupport.assertBare(
        lastMemo(done, .systemSmall, background: false), family: .systemSmall, name: "last-memo-done", wallpaper: false)
      WidgetSnapshotSupport.assertBare(
        lastMemo(WidgetSamples.line(.needsRoute, headline: "Router bestellen"), .systemSmall, background: false),
        family: .systemSmall, name: "last-memo-needs-route", wallpaper: false)
      WidgetSnapshotSupport.assertBare(
        record(.systemSmall), family: .systemSmall, name: "record", wallpaper: false)
    }

    @Test("German strings fit: small and rectangular", .tags(.snapshot))
    func german() {
      let needsRoute = WidgetSamples.line(.needsRoute, headline: "Router bestellen und Netzwerkplan prüfen")
      WidgetSnapshotSupport.assertHome(
        lastMemo(needsRoute, .systemSmall), family: .systemSmall, name: "small-needs-route", locale: "de")
      WidgetSnapshotSupport.assertHome(
        lastMemo(.noData, .systemMedium), family: .systemMedium, name: "medium-no-data", locale: "de")
      WidgetSnapshotSupport.assertBare(
        lastMemo(WidgetSamples.line(.processing), .accessoryRectangular, rendering: .vibrant, background: false),
        family: .accessoryRectangular, name: "rectangular-processing", locale: "de")
      WidgetSnapshotSupport.assertBare(
        lastMemo(needsRoute, .accessoryInline, rendering: .vibrant, background: false),
        family: .accessoryInline, name: "inline-needs-route", locale: "de")
    }

    @Test("accented and vibrant rendering: no state color, the accent group marked", .tags(.snapshot))
    func monochrome() {
      let needsRoute = WidgetSamples.line(.needsRoute, headline: "Router bestellen und Netzwerkplan prüfen")
      WidgetSnapshotSupport.assertBare(
        lastMemo(needsRoute, .systemSmall, rendering: .accented, background: false), family: .systemSmall,
        name: "last-memo-accented")
      WidgetSnapshotSupport.assertBare(
        record(.systemSmall, rendering: .accented), family: .systemSmall, name: "record-accented")
    }
  }
#endif
