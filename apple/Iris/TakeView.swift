import IrisCapture
import IrisCore
import IrisUI
import SwiftUI

/// The full take screen over the app: `TakeScreen` fed by the model, plus the discard confirmation and the microphone list.
struct TakeView: View {
  @Bindable var model: TakeModel
  @State private var confirmsDiscard = false

  var body: some View {
    TakeScreen(
      isPaused: model.isPaused, start: model.timerStart ?? Date(), frozenAt: model.timerFrozenAt,
      modeLabel: model.modeTitle, inputName: model.inputName, levels: model.levels, notice: model.screenNotice,
      labels: Self.labels, onMinimize: { model.showsFull = false },
      onPickInput: { Task { await model.openInputPicker() } },
      onTogglePause: { Task { await model.togglePause() } },
      onStop: { Task { await model.stop() } },
      onDiscard: { confirmsDiscard = true }
    )
    .disabled(model.isEnding)
    .confirmationDialog(
      String(localized: "Discard this recording?", comment: "Take discard confirmation title"),
      isPresented: $confirmsDiscard, titleVisibility: .visible
    ) {
      Button(String(localized: "Discard", comment: "Discards the take"), role: .destructive) {
        Task { await model.discard() }
      }
      .accessibilityIdentifier("take.discard.confirm")
    } message: {
      Text("Nothing is sent.", comment: "Take discard confirmation message")
    }
    .sheet(isPresented: $model.showsInputPicker) {
      InputPickerSheet(model: model)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
  }

  private static var labels: TakeScreenLabels {
    TakeScreenLabels(
      recording: String(localized: "Recording", comment: "Take screen status"),
      paused: String(localized: "Paused", comment: "Take screen status"),
      stop: String(localized: "Stop and send", comment: "Take screen control"),
      discard: String(localized: "Discard", comment: "Take screen control"),
      pause: String(localized: "Pause", comment: "Take screen control"),
      resume: String(localized: "Resume", comment: "Take screen control"),
      microphone: String(localized: "Microphone", comment: "Take screen control"),
      minimize: String(localized: "Back to the app", comment: "Take screen control"))
  }
}

/// The microphones the take can use; picking one rolls the segment over so a file never holds two inputs.
private struct InputPickerSheet: View {
  let model: TakeModel

  var body: some View {
    NavigationStack {
      List(model.inputs, id: \.uid) { port in
        Button {
          Task { await model.pickInput(port) }
        } label: {
          HStack {
            Text(verbatim: port.name)
              .foregroundStyle(Theme.Ink.primary)
            Spacer()
            if port.name == model.inputName {
              Image(systemName: "checkmark")
                .foregroundStyle(Theme.Accent.tint)
                .accessibilityHidden(true)
            }
          }
        }
        .accessibilityIdentifier("take.input.row")
      }
      .navigationTitle(String(localized: "Microphone", comment: "Microphone picker title"))
      .navigationBarTitleDisplayMode(.inline)
    }
    .accessibilityIdentifier("take.input.list")
  }
}

/// The compact banner a running take continues as while the user browses; tapping it brings the take screen back.
struct TakeBannerView: View {
  let model: TakeModel

  var body: some View {
    TakeBanner(
      isPaused: model.isPaused, start: model.timerStart ?? Date(), frozenAt: model.timerFrozenAt,
      title: [model.modeTitle, model.inputName].compactMap { $0 }.joined(separator: " · "),
      detail: model.sendingText, stopLabel: String(localized: "Stop and send", comment: "Take banner control"),
      openHint: String(localized: "Opens the recording", comment: "Take banner hint"),
      onOpen: { model.showsFull = true }, onStop: { Task { await model.stop() } }
    )
    .padding(.horizontal, Theme.Spacing.lg)
    .padding(.bottom, Theme.Spacing.sm)
    .accessibilityIdentifier("take.banner")
  }
}

/// Pins the take banner under the navigation bar of a screen while a take runs and the full take screen is down. Every
/// screen of the app applies it to its content, so the banner follows the user wherever they browse (a banner over the
/// whole `TabView` would sit on top of the navigation bar's buttons).
private struct TakeBannerInset: ViewModifier {
  @Environment(TakeModel.self) private var take: TakeModel?

  func body(content: Content) -> some View {
    content
      .safeAreaBar(edge: .top, spacing: 0) {
        if let take, take.isActive, !take.showsFull {
          TakeBannerView(model: take)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
      .animation(.snappy, value: take.map { $0.isActive && !$0.showsFull })
  }
}

extension View {
  /// The compact take banner under this screen's navigation bar.
  func takeBanner() -> some View {
    modifier(TakeBannerInset())
  }
}

/// The record control above the tab bar on every screen: a tap starts a take in Auto, a long press picks the mode.
struct RecordAccessory: View {
  let model: TakeModel

  var body: some View {
    Button {
      Task { await model.start() }
    } label: {
      Label(String(localized: "Record", comment: "Starts a voice memo"), systemImage: "mic.fill")
        .themeFont(.subheadline, weight: .semibold)
        .foregroundStyle(Theme.Accent.tint)
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(!model.canStart)
    .contextMenu {
      ForEach([MemoMode.auto, .journal, .hermes, .chat], id: \.self) { mode in
        Button(mode.composerTitle) { Task { await model.start(mode: mode) } }
      }
    }
    .accessibilityIdentifier("record.start")
  }
}
