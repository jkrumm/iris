import AppIntents
import IrisCore
import IrisUI
import SwiftUI
import WidgetKit

/// The Live Activity of one memo. The phone sets `recording`, `paused` and `uploading` itself while the take is on the
/// device; the server's pushes then carry `processing`, `needsRoute`, `done` and `failed`. The views are IrisUI's (snapshot
/// tested); this file maps the state onto them and wires the icon controls to the `LiveActivityIntent`s. Rendering on a
/// device is checked on the device checklist.
struct MemoLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: MemoAttributes.self) { context in
      LiveActivityPanel(context.presentation) {
        RecordingControls(paused: context.state.phase == .paused, onDark: false)
      } doneAction: {
        PlayReplyControl(memoID: context.attributes.memoId, onDark: false)
      }
      .padding(Theme.Spacing.lg)
      .activityBackgroundTint(Theme.Surface.panel)
    } dynamicIsland: { context in
      let presentation = context.presentation
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          ActivityPhaseTitle(presentation, onDark: true)
        }
        DynamicIslandExpandedRegion(.trailing) {
          ActivityHeaderTrailing(presentation, onDark: true)
        }
        DynamicIslandExpandedRegion(.bottom) {
          LiveActivityPanel(presentation, style: .island) {
            RecordingControls(paused: context.state.phase == .paused, onDark: true)
          } doneAction: {
            PlayReplyControl(memoID: context.attributes.memoId, onDark: true)
          }
        }
      } compactLeading: {
        IslandGlyph(phase: presentation.phase)
      } compactTrailing: {
        IslandCompactTrailing(presentation)
      } minimal: {
        IslandGlyph(phase: presentation.phase)
      }
    }
  }
}

/// Stop, swap the microphone, pause or resume: each an intent that runs in the app, which holds the take.
private struct RecordingControls: View {
  let paused: Bool
  let onDark: Bool

  var body: some View {
    ActivityControlsRow {
      Button(intent: StopMemoIntent()) {
        ActivityControlLabel(.stop, title: String(localized: "Stop", comment: "Live Activity control"))
      }
    } switchInput: {
      Button(intent: SwitchInputIntent()) {
        ActivityControlLabel(
          .switchInput, title: String(localized: "Switch microphone", comment: "Live Activity control"),
          onDark: onDark)
      }
    } pause: {
      Button(intent: PauseMemoIntent()) {
        ActivityControlLabel(
          paused ? .resume : .pause,
          title: paused
            ? String(localized: "Resume", comment: "Live Activity control")
            : String(localized: "Pause", comment: "Live Activity control"),
          onDark: onDark)
      }
    }
    .buttonStyle(.plain)
  }
}

/// Play on the done card: speaks the memo's reply through the app (`PlayReplyIntent`). Compile-checked only; whether the
/// system lets a suspended app start playback from here is spike S3.
private struct PlayReplyControl: View {
  let memoID: String
  let onDark: Bool

  var body: some View {
    Button(intent: PlayReplyIntent(memoID: memoID)) {
      ActivityControlLabel(.play, title: String(localized: "Play", comment: "Live Activity control"), onDark: onDark)
    }
    .buttonStyle(.plain)
  }
}

extension ActivityViewContext<MemoAttributes> {
  fileprivate var presentation: ActivityPresentation {
    let phase = state.phase.activityPhase
    return ActivityPresentation(
      phase: phase, phaseTitle: state.phase.title, modeLabel: attributes.mode.title,
      subtitle: state.phase.subtitle, inputName: state.inputName, routeChip: state.routeChip,
      headline: state.headline, note: phase == .recording || phase == .paused ? state.headline : nil,
      start: attributes.startedAt)
  }
}

extension LiveActivityPhase {
  fileprivate var activityPhase: ActivityPhase {
    switch self {
    case .recording: .recording
    case .paused: .paused
    case .uploading: .uploading
    case .processing: .processing
    case .needsRoute: .needsRoute
    case .done: .done
    case .failed: .failed
    }
  }

  fileprivate var title: String {
    switch self {
    case .recording: String(localized: "Recording", comment: "Live Activity phase")
    case .paused: String(localized: "Paused", comment: "Live Activity phase")
    case .uploading: String(localized: "Uploading", comment: "Live Activity phase")
    case .processing: String(localized: "Processing", comment: "Live Activity phase")
    case .needsRoute: String(localized: "Needs a route", comment: "Live Activity phase")
    case .done: String(localized: "Done", comment: "Live Activity phase")
    case .failed: String(localized: "Failed", comment: "Live Activity phase")
    }
  }

  /// The line under the phase for the phases that have no timer or headline of their own.
  fileprivate var subtitle: String? {
    switch self {
    case .uploading: String(localized: "Sending the recording", comment: "Live Activity subtitle")
    case .processing: String(localized: "Iris is working on it", comment: "Live Activity subtitle")
    case .needsRoute: String(localized: "Where should this go?", comment: "Live Activity subtitle")
    case .failed: String(localized: "Iris could not finish this memo", comment: "Live Activity subtitle")
    case .recording, .paused, .done: nil
    }
  }
}

extension MemoMode {
  fileprivate var title: String {
    switch self {
    case .auto, .unknown: String(localized: "Auto", comment: "Memo mode")
    case .journal: String(localized: "Journal", comment: "Memo mode")
    case .hermes: String(localized: "Hermes", comment: "Memo mode")
    case .tab: String(localized: "Tab", comment: "Memo mode")
    case .chat: String(localized: "Chat", comment: "Memo mode")
    case .transcribe: String(localized: "Transcribe", comment: "Memo mode")
    }
  }
}
