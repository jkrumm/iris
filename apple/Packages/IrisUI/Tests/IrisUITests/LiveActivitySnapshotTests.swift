#if os(iOS)
  import SnapshotTesting
  import SwiftUI
  import Testing

  @testable import IrisUI

  /// The Lock Screen card and the Dynamic Island presentations, on the pinned simulator. The island is drawn by
  /// ``IslandMock`` (a black pill or card): the system draws the real one, these show what the widget puts into it.
  @MainActor
  @Suite(.snapshots(record: SnapshotSupport.record))
  struct LiveActivitySnapshotTests {
    private func card(_ presentation: ActivityPresentation, controls: Bool = false) -> some View {
      LiveActivityPanel(presentation) {
        if controls { CaptureSamples.controls(paused: presentation.phase == .paused, onDark: false) }
      }
      .padding(Theme.Spacing.lg)
      .background(Theme.Surface.panel, in: .rect(cornerRadius: 24))
      .padding(Theme.Spacing.md)
    }

    @Test("lock screen: recording with controls", .tags(.snapshot))
    func lockRecording() {
      SnapshotSupport.assertLightAndDark(
        card(CaptureSamples.presentation(.recording), controls: true), width: 390, height: 200)
    }

    @Test("lock screen: recording while an earlier memo is still sending", .tags(.snapshot))
    func lockRecordingWithQueue() {
      let presentation = CaptureSamples.presentation(.recording, note: "1 earlier memo is still sending")
      SnapshotSupport.assertLightAndDark(card(presentation, controls: true), width: 390, height: 250)
    }

    @Test("lock screen: paused", .tags(.snapshot))
    func lockPaused() {
      SnapshotSupport.assertLightAndDark(
        card(CaptureSamples.presentation(.paused), controls: true), width: 390, height: 200)
    }

    @Test("lock screen: uploading and processing show the stage dashes", .tags(.snapshot))
    func lockProgress() {
      let both = VStack(spacing: 0) {
        card(CaptureSamples.presentation(.uploading))
        card(CaptureSamples.presentation(.processing))
      }
      SnapshotSupport.assertLightAndDark(both, width: 390, height: 300)
    }

    @Test("lock screen: needs a route", .tags(.snapshot))
    func lockNeedsRoute() {
      SnapshotSupport.assertLightAndDark(
        card(CaptureSamples.presentation(.needsRoute, routeChip: "Hermes?")), width: 390, height: 150)
    }

    @Test("lock screen: the done card keeps the checkmark on the first line", .tags(.snapshot))
    func lockDone() {
      let short = CaptureSamples.presentation(.done, headline: "Weekly plan agreed", routeChip: "Hermes")
      let long = CaptureSamples.presentation(
        .done, headline: "Weekly plan agreed, release on Thursday, two follow-ups assigned", routeChip: "Hermes")
      let both = VStack(spacing: 0) {
        card(short)
        card(long)
      }
      SnapshotSupport.assertLightAndDark(both, width: 390, height: 280)
    }

    @Test("lock screen: failed", .tags(.snapshot))
    func lockFailed() {
      SnapshotSupport.assertLightAndDark(card(CaptureSamples.presentation(.failed)), width: 390, height: 110)
    }

    // MARK: Dynamic Island

    private func compact(_ phase: ActivityPhase) -> some View {
      let presentation = CaptureSamples.presentation(phase)
      return IslandMock(.compact) {
        IslandGlyph(phase: phase)
      } trailing: {
        IslandCompactTrailing(presentation)
      }
    }

    private func minimal(_ phase: ActivityPhase) -> some View {
      IslandMock(.minimal) {
        IslandGlyph(phase: phase)
      } trailing: {
        EmptyView()
      }
    }

    @Test("island: compact and minimal across the phases", .tags(.snapshot))
    func compactAndMinimal() {
      let rows = VStack(spacing: 12) {
        ForEach([ActivityPhase.recording, .paused, .uploading, .processing, .needsRoute, .done, .failed], id: \.self) {
          phase in
          HStack(spacing: 12) {
            compact(phase)
            minimal(phase)
          }
        }
      }
      .padding(.vertical, Theme.Spacing.md)
      SnapshotSupport.assertLightAndDark(rows, width: 390, height: 420)
    }

    private func expanded(_ presentation: ActivityPresentation, controls: Bool = false) -> some View {
      IslandMock(.expanded) {
        ActivityPhaseTitle(presentation, onDark: true)
      } trailing: {
        ActivityHeaderTrailing(presentation, onDark: true)
      } bottom: {
        LiveActivityPanel(presentation, style: .island) {
          if controls { CaptureSamples.controls(paused: presentation.phase == .paused) }
        }
      }
      .padding(.vertical, Theme.Spacing.md)
    }

    @Test("island expanded: recording with icon controls", .tags(.snapshot))
    func expandedRecording() {
      SnapshotSupport.assertLightAndDark(
        expanded(CaptureSamples.presentation(.recording), controls: true), width: 390, height: 230)
    }

    @Test("island expanded: recording, an earlier memo still sending", .tags(.snapshot))
    func expandedRecordingWithQueue() {
      let presentation = CaptureSamples.presentation(.recording, note: "1 earlier memo is still sending")
      SnapshotSupport.assertLightAndDark(expanded(presentation, controls: true), width: 390, height: 290)
    }

    @Test("island expanded: processing with the stage dashes", .tags(.snapshot))
    func expandedProcessing() {
      SnapshotSupport.assertLightAndDark(expanded(CaptureSamples.presentation(.processing)), width: 390, height: 170)
    }

    @Test("island expanded: done", .tags(.snapshot))
    func expandedDone() {
      let presentation = CaptureSamples.presentation(
        .done, headline: "Weekly plan agreed, release on Thursday", routeChip: "Hermes")
      SnapshotSupport.assertLightAndDark(expanded(presentation), width: 390, height: 170)
    }
  }
#endif
