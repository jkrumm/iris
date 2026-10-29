#if os(iOS)
  import Foundation
  import SwiftUI

  @testable import IrisUI

  /// Fixed instants and sample data for the capture snapshots: the timers stand still at 12:48.
  enum CaptureSamples {
    // In the past: a timer counting up from a future instant reads 0:00.
    static let now = Date(timeIntervalSince1970: 1_767_225_600)
    static let start = now.addingTimeInterval(-768)

    /// A repeatable waveform, newest on the right.
    static let levels: [Float] = (0..<44).map { index in
      let wave = abs(sin(Double(index) * 0.55)) * 0.7 + abs(cos(Double(index) * 0.21)) * 0.25
      return Float(min(max(wave, 0.08), 1))
    }

    static let labels = TakeScreenLabels(
      recording: "Recording", paused: "Paused", stop: "Stop", discard: "Discard", pause: "Pause", resume: "Resume",
      microphone: "Microphone", minimize: "Minimize")

    static func presentation(
      _ phase: ActivityPhase, headline: String? = nil, routeChip: String? = nil, note: String? = nil
    ) -> ActivityPresentation {
      let title: String
      let subtitle: String?
      switch phase {
      case .recording: (title, subtitle) = ("Recording", nil)
      case .paused: (title, subtitle) = ("Paused", nil)
      case .uploading: (title, subtitle) = ("Uploading", "Sending the recording")
      case .processing: (title, subtitle) = ("Processing", "Iris is working on it")
      case .needsRoute: (title, subtitle) = ("Needs a route", "Where should this go?")
      case .done: (title, subtitle) = ("Done", nil)
      case .failed: (title, subtitle) = ("Failed", "Iris could not send this memo")
      }
      return ActivityPresentation(
        phase: phase, phaseTitle: title, modeLabel: "Auto", subtitle: subtitle,
        inputName: phase == .recording || phase == .paused ? "iPhone Microphone" : nil, routeChip: routeChip,
        headline: headline, note: note, start: start, timerFrozenAt: now)
    }

    /// The recording controls as the widget lays them out, without the intents.
    @MainActor static func controls(paused: Bool = false, onDark: Bool = true) -> some View {
      ActivityControlsRow {
        ActivityControlLabel(.stop, title: "Stop")
      } switchInput: {
        ActivityControlLabel(.switchInput, title: "Switch microphone", onDark: onDark)
      } pause: {
        ActivityControlLabel(paused ? .resume : .pause, title: paused ? "Resume" : "Pause", onDark: onDark)
      }
    }
  }
#endif
