import AppKit
import IrisCapture
import IrisUI
import SwiftUI

/// The floating panel's content: the running time, the level, the microphone and Stop / Cancel while a take records, and a
/// short message when it could not start or lost something.
struct RecordingPanelView: View {
  static let width: CGFloat = 360
  let model: RecordingPanelModel
  /// Told the content's size whenever it changes (a message is taller than the running take), so the panel follows it.
  var onResize: (CGSize) -> Void = { _ in }

  var body: some View {
    Group {
      switch model.phase {
      case .idle: EmptyView()
      case .starting: progress(String(localized: "Starting…", comment: "Recording panel while the microphone comes up"))
      case .stopping: progress(String(localized: "Saving…", comment: "Recording panel while the take is closed"))
      case .recording(let since): recording(since: since)
      case .failed(let failure): message(for: failure)
      }
    }
    .padding(Theme.Spacing.lg)
    .frame(width: Self.width, alignment: .leading)
    .background(.regularMaterial, in: .rect(cornerRadius: Theme.Radius.floating))
    .overlay { RoundedRectangle(cornerRadius: Theme.Radius.floating).stroke(Theme.Surface.hairline) }
    .onGeometryChange(for: CGSize.self) {
      $0.size
    } action: {
      onResize($0)
    }
    .accessibilityIdentifier("mac.recording.panel")
  }

  private func progress(_ title: String) -> some View {
    HStack(spacing: Theme.Spacing.sm) {
      ProgressView().controlSize(.small)
      Text(verbatim: title)
        .themeFont(.body)
        .foregroundStyle(Theme.Ink.secondary)
    }
  }

  private func recording(since: Date) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      HStack(spacing: Theme.Spacing.sm) {
        Image(systemName: "circle.fill")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(Theme.Status.bad)
          .accessibilityHidden(true)
        ElapsedTimerText(start: since)
          .themeFont(.title3, weight: .semibold)
          .foregroundStyle(Theme.Ink.primary)
          .accessibilityIdentifier("mac.recording.time")
        LevelWaveform(levels: model.recentLevels)
          .frame(height: Theme.Spacing.xl)
          .accessibilityIdentifier("mac.recording.level")
      }
      HStack(spacing: Theme.Spacing.sm) {
        microphonePicker
        Spacer(minLength: Theme.Spacing.sm)
        Button(String(localized: "Cancel", comment: "Drops the running take")) { model.cancel() }
          .accessibilityIdentifier("mac.recording.cancel")
        Button(String(localized: "Stop", comment: "Ends the running take and sends it")) { model.stop() }
          .buttonStyle(.borderedProminent)
          .tint(Theme.Status.bad)
          .accessibilityIdentifier("mac.recording.stop")
      }
    }
  }

  private var microphonePicker: some View {
    Picker(
      String(localized: "Microphone", comment: "Recording panel microphone picker"),
      selection: Binding(
        get: { model.microphones.current?.uid ?? "" },
        set: { model.select(microphone: $0) })
    ) {
      ForEach(model.microphones.inputs, id: \.uid) { input in
        Text(verbatim: input.name).tag(input.uid)
      }
    }
    .pickerStyle(.menu)
    .labelsHidden()
    .fixedSize()
    .disabled(model.microphones.inputs.count < 2)
    .accessibilityIdentifier("mac.recording.microphone")
  }

  private func message(for failure: RecordingPanelModel.Failure) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      Text(verbatim: Self.text(for: failure))
        .themeFont(.body)
        .foregroundStyle(Theme.Ink.primary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("mac.recording.message")
      HStack {
        Spacer()
        if failure == .microphoneDenied {
          Button(String(localized: "Open Settings", comment: "Opens the Microphone privacy settings")) {
            Self.openMicrophoneSettings()
          }
          .accessibilityIdentifier("mac.recording.open-settings")
        }
        Button(String(localized: "Close", comment: "Closes the recording panel's message")) { model.cancel() }
          .accessibilityIdentifier("mac.recording.close")
      }
    }
  }

  static func text(for failure: RecordingPanelModel.Failure) -> String {
    switch failure {
    case .notConfigured:
      String(
        localized: "Add the server address and token in Iris Settings first.",
        comment: "Recording panel: no connection saved")
    case .microphoneDenied:
      String(
        localized: "Iris may not use the microphone. Allow it in System Settings › Privacy & Security › Microphone.",
        comment: "Recording panel: microphone permission refused")
    case .couldNotStart:
      String(localized: "The recording could not start.", comment: "Recording panel: engine failed to start")
    case .nothingRecorded:
      String(localized: "Nothing was recorded.", comment: "Recording panel: a take without any audio")
    case .stoppedEarly:
      String(
        localized: "The recording stopped early. What was captured is being sent.",
        comment: "Recording panel: the recorder failed mid-take")
    case .lost:
      String(localized: "The recording could not be saved.", comment: "Recording panel: stopping lost the audio")
    }
  }

  private static func openMicrophoneSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
      return
    }
    NSWorkspace.shared.open(url)
  }
}

/// A panel that never takes focus: the hotkey records while the user keeps typing in another app.
final class NonActivatingPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Owns the floating `NSPanel` and shows it while the model has something to show.
@MainActor
final class RecordingPanelController {
  static let title = "Iris recording"

  private let model: RecordingPanelModel
  private(set) var panel: NSPanel?

  init(model: RecordingPanelModel) {
    self.model = model
    model.onVisibilityChange = { [weak self] visible in
      if visible { self?.show() } else { self?.hide() }
    }
  }

  func show() {
    let panel = panel ?? makePanel()
    self.panel = panel
    place(panel, size: panel.contentView?.fittingSize ?? .zero)
    panel.orderFrontRegardless()
  }

  func hide() {
    panel?.orderOut(nil)
  }

  private func makePanel() -> NSPanel {
    let view = RecordingPanelView(model: model) { [weak self] size in
      guard let self, let panel = self.panel, panel.isVisible else { return }
      self.place(panel, size: size)
    }
    let hosting = NSHostingView(rootView: view)
    hosting.sizingOptions = [.intrinsicContentSize]
    let panel = NonActivatingPanel(
      contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.title = Self.title
    panel.contentView = hosting
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = true
    panel.isReleasedWhenClosed = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    return panel
  }

  /// Top centre of the screen under the menu bar, `size` big.
  private func place(_ panel: NSPanel, size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }
    panel.setContentSize(size)
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    let frame = screen.visibleFrame
    panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - Theme.Spacing.xl))
  }
}
