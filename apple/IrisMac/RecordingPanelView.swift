import AppKit
import IrisCapture
import IrisUI
import SwiftUI

/// The floating panel's content: one row of Stop, the running time, the level, the microphone and Cancel while a take
/// records, and a short message when it could not start or lost something.
struct RecordingPanelView: View {
  static let width = Theme.Spacing.panelWidth
  /// `.panel .tm`: 22 pt, medium. The type scale has no 22, so the timer's size is named here.
  private static let timerSize: CGFloat = 22
  let model: RecordingPanelModel
  /// The recorded key ("⌃⌥M"); nil when none is set. Read when the view draws.
  var shortcut: () -> String? = { nil }
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
    .padding(.horizontal, Theme.Spacing.panelHorizontal)
    .padding(.vertical, Theme.Spacing.panelVertical)
    .frame(width: Self.width, alignment: .leading)
    .background(.regularMaterial, in: .rect(cornerRadius: Theme.Spacing.panelRadius))
    .overlay { RoundedRectangle(cornerRadius: Theme.Spacing.panelRadius).stroke(Theme.Surface.hairline) }
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
        .themeFont(.subheadline)
        .foregroundStyle(Theme.Ink.secondary)
    }
  }

  /// `.panel`: one row, stop beside the timer, then the level, the microphone and cancel.
  private func recording(since: Date) -> some View {
    HStack(spacing: Theme.Spacing.panelGap) {
      stopButton
      ElapsedTimerText(start: since)
        .font(.system(size: Self.timerSize, weight: .medium))
        .foregroundStyle(Theme.Ink.primary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("mac.recording.time")
      LevelWaveform(levels: model.recentLevels)
        .frame(height: Theme.Spacing.panelLevelHeight)
        .accessibilityIdentifier("mac.recording.level")
      microphonePicker.layoutPriority(1)
      cancelButton.layoutPriority(1)
    }
  }

  /// `.panel .btn.stop`: the one red element. The key that stops the take is its tooltip and VoiceOver hint.
  private var stopButton: some View {
    let hint = shortcut().map {
      String(localized: "\($0) to stop", comment: "Recording panel: the key that stops the take, e.g. ⌃⌥M")
    }
    return Button {
      model.stop()
    } label: {
      Image(systemName: "stop.fill")
        .themeFont(.footnote)
        .foregroundStyle(Theme.Accent.onFill)
        .frame(width: Theme.Spacing.panelStopSize, height: Theme.Spacing.panelStopSize)
        .background(Theme.Status.bad, in: .circle)
        .contentShape(.circle)
    }
    .buttonStyle(.plain)
    .keyboardShortcut(.defaultAction)
    .help(hint ?? String(localized: "Stop", comment: "Ends the running take and sends it"))
    .accessibilityLabel(String(localized: "Stop", comment: "Ends the running take and sends it"))
    .accessibilityHint(hint ?? "")
    .accessibilityIdentifier("mac.recording.stop")
  }

  /// Drops the take (nothing is sent); an icon, so the row never outgrows the panel.
  private var cancelButton: some View {
    Button {
      model.cancel()
    } label: {
      Image(systemName: "xmark")
        .themeFont(.footnote, weight: .semibold)
        .foregroundStyle(Theme.Ink.secondary)
        .frame(width: Theme.Spacing.panelButtonHeight, height: Theme.Spacing.panelButtonHeight)
        .background(Theme.Surface.subtle, in: .circle)
        .overlay { Circle().strokeBorder(Theme.Surface.border, lineWidth: 0.5) }
        .contentShape(.circle)
    }
    .buttonStyle(.plain)
    .help(String(localized: "Cancel", comment: "Drops the running take"))
    .accessibilityLabel(String(localized: "Cancel", comment: "Drops the running take"))
    .accessibilityIdentifier("mac.recording.cancel")
  }

  /// `.panel .chip`: the microphone as an icon and a chevron; the device's name is the tooltip and the VoiceOver value.
  private var microphonePicker: some View {
    let inputs = model.microphones.inputs
    let name = model.microphones.current?.name ?? ""
    return Menu {
      ForEach(inputs, id: \.uid) { input in
        Button(input.name) { model.select(microphone: input.uid) }
      }
    } label: {
      HStack(spacing: Theme.Spacing.hair) {
        Image(systemName: "mic").accessibilityHidden(true)
        Image(systemName: "chevron.down").themeFont(.micro, weight: .semibold).accessibilityHidden(true)
      }
      .themeFont(.footnote, weight: .medium)
      .foregroundStyle(Theme.Ink.secondary)
      .padding(.horizontal, Theme.Spacing.cozy)
      .frame(height: Theme.Spacing.panelChipHeight)
      .background(Theme.Surface.subtle, in: .capsule)
      .overlay { Capsule().strokeBorder(Theme.Surface.border, lineWidth: 0.5) }
      .contentShape(.capsule)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .disabled(inputs.count < 2)
    .help(name)
    .accessibilityLabel(String(localized: "Microphone", comment: "Recording panel microphone picker"))
    .accessibilityValue(name)
    .accessibilityIdentifier("mac.recording.microphone")
  }

  private func message(for failure: RecordingPanelModel.Failure) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      Text(verbatim: Self.text(for: failure))
        .themeFont(.subheadline)
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
          .keyboardShortcut(.cancelAction)
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

/// A panel that never activates Iris: the hotkey records while the user keeps typing in another app.
///
/// It **can** become key (a borderless window refuses by default), but only by the user's click on it: it is shown with
/// `orderFrontRegardless`, which changes neither the key nor the main window, so the app in front keeps its keystrokes until then.
/// Once clicked, the panel is key without Iris becoming the active app (`.nonactivatingPanel`, set at init: the bit cannot be
/// added or removed on a live panel), so the Microphone menu opens as a menu, Return stops the take and Escape closes a message.
/// `becomesKeyOnlyIfNeeded` stays `false`: a click anywhere on the panel, not only on a text field, hands it the keys.
/// What was checked on the mini and what only a MacBook can show: TDD §5, `MacTests/RecordingPanelKeyTests`.
final class NonActivatingPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// Owns the floating `NSPanel` and shows it while the model has something to show.
@MainActor
final class RecordingPanelController {
  static let title = "Iris recording"

  private let model: RecordingPanelModel
  private let shortcut: () -> String?
  private(set) var panel: NSPanel?

  init(model: RecordingPanelModel, shortcut: @escaping () -> String? = { nil }) {
    self.model = model
    self.shortcut = shortcut
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
    let view = RecordingPanelView(model: model, shortcut: shortcut) { [weak self] size in
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
