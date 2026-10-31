import AppKit
import Foundation
import IrisCapture
import KeyboardShortcuts
import Testing

@testable import IrisMac

@MainActor
@Suite("Recording panel model")
struct RecordingPanelModelTests {
  private struct Harness {
    let model: RecordingPanelModel
    let engine: FakeTakeEngine
    let permission: FakeMicrophonePermission
    let visibility: Visibility
  }

  /// Every show / hide the model asked the panel for.
  @MainActor
  final class Visibility {
    var changes: [Bool] = []
  }

  private func harness(
    access: MicrophoneAccess = .granted, answer: Bool = true, configured: Bool = true
  ) -> Harness {
    let engine = FakeTakeEngine()
    let permission = FakeMicrophonePermission(access, answer: answer)
    let model = RecordingPanelModel(engine: engine, permission: permission, isConfigured: { configured })
    let visibility = Visibility()
    model.onVisibilityChange = { visibility.changes.append($0) }
    return Harness(model: model, engine: engine, permission: permission, visibility: visibility)
  }

  private func isRecording(_ model: RecordingPanelModel) -> Bool { model.isRecording }

  @Test("the key starts a take and shows the panel; the key again stops it and hides the panel")
  func toggleStartsAndStops() async {
    let h = harness()
    h.model.toggle()
    await h.model.settled()
    #expect(isRecording(h.model) && h.model.isVisible)
    #expect(h.model.microphones.current?.uid == FakeAudioDeviceDirectory.builtIn.uid)
    h.model.toggle()
    await h.model.settled()
    #expect(h.model.phase == .idle)
    #expect(h.engine.calls == ["start", "stop"])
    #expect(h.visibility.changes == [true, false])
  }

  @Test("without a saved connection the panel says so and nothing starts")
  func notConfigured() async {
    let h = harness(configured: false)
    h.model.toggle()
    await h.model.settled()
    #expect(h.model.phase == .failed(.notConfigured))
    #expect(h.engine.calls.isEmpty)
  }

  @Test("a refused microphone shows the failure without asking again or starting")
  func permissionDenied() async {
    let h = harness(access: .denied)
    h.model.toggle()
    await h.model.settled()
    #expect(h.model.phase == .failed(.microphoneDenied))
    #expect(h.permission.requests == 0 && h.engine.calls.isEmpty)
  }

  @Test("an open permission question is asked once and the take starts on yes")
  func permissionAsked() async {
    let h = harness(access: .undetermined)
    h.model.toggle()
    await h.model.settled()
    #expect(h.permission.requests == 1)
    #expect(isRecording(h.model))
  }

  @Test("a no at the prompt is the denied failure")
  func permissionRefusedAtThePrompt() async {
    let h = harness(access: .undetermined, answer: false)
    h.model.toggle()
    await h.model.settled()
    #expect(h.model.phase == .failed(.microphoneDenied))
    #expect(h.engine.calls.isEmpty)
  }

  @Test("an engine that cannot start leaves a message, and the key tries again")
  func startFailure() async {
    let h = harness()
    h.engine.failStart(with: CaptureError.engineFailure("no input"))
    h.model.toggle()
    await h.model.settled()
    #expect(h.model.phase == .failed(.couldNotStart))
    h.engine.failStart(with: nil)
    h.model.toggle()
    await h.model.settled()
    #expect(isRecording(h.model))
  }

  @Test("a second press while a start is running is dropped, not queued as a stop")
  func pressesDuringStartAreDropped() async {
    let h = harness(access: .undetermined)
    h.model.toggle()
    h.model.toggle()
    h.model.toggle()
    await h.model.settled()
    #expect(isRecording(h.model))
    #expect(h.engine.calls == ["start"])
  }

  @Test("a take that closed no segment says nothing was recorded; Close dismisses it")
  func nothingRecorded() async {
    let h = harness()
    h.engine.endStop(with: .nothingRecorded)
    h.model.toggle()
    await h.model.settled()
    h.model.stop()
    await h.model.settled()
    #expect(h.model.phase == .failed(.nothingRecorded))
    h.model.cancel()
    #expect(h.model.phase == .idle && h.visibility.changes == [true, false])
  }

  @Test("a stop that loses the audio is a failure, not a silent idle")
  func stopFailure() async {
    let h = harness()
    h.engine.failStop(with: CaptureError.recordingFailed("disk"))
    h.model.toggle()
    await h.model.settled()
    h.model.stop()
    await h.model.settled()
    #expect(h.model.phase == .failed(.lost))
  }

  @Test("Cancel drops the take without stopping it")
  func cancelDropsTheTake() async {
    let h = harness()
    h.model.toggle()
    await h.model.settled()
    h.model.cancel()
    await h.model.settled()
    #expect(h.model.phase == .idle)
    #expect(h.engine.calls == ["start", "cancel"])
  }

  @Test("another microphone is applied during the take only, and the list follows it")
  func selectMicrophone() async {
    let h = harness()
    h.model.select(microphone: FakeAudioDeviceDirectory.usb.uid)
    await h.model.settled()
    #expect(h.engine.calls.isEmpty)  // not recording: ignored
    h.model.toggle()
    await h.model.settled()
    h.model.select(microphone: FakeAudioDeviceDirectory.builtIn.uid)  // already in use
    h.model.select(microphone: FakeAudioDeviceDirectory.usb.uid)
    await h.model.settled()
    #expect(h.engine.calls == ["start", "select:\(FakeAudioDeviceDirectory.usb.uid)"])
    #expect(h.model.microphones.current?.uid == FakeAudioDeviceDirectory.usb.uid)
  }

  @Test("a microphone that appears or goes shows in the panel")
  func microphoneListFollowsTheDevices() async {
    let h = harness()
    h.model.toggle()
    await h.model.settled()
    h.engine.setMicrophones(Microphones(inputs: [FakeAudioDeviceDirectory.usb], current: FakeAudioDeviceDirectory.usb))
    #expect(await eventually { h.model.microphones.inputs.count == 1 })
  }

  @Test("the level and the last bars follow the engine, capped to the waveform, and are cleared with the take")
  func levels() async {
    let h = harness()
    h.model.toggle()
    await h.model.settled()
    for index in 0..<(RecordingPanelModel.waveformBars + 10) {
      h.engine.level(Float(index % 10) / 10)
      #expect(await eventually { h.model.recentLevels.last == Float(index % 10) / 10 || index == 0 })
    }
    #expect(h.model.recentLevels.count == RecordingPanelModel.waveformBars)
    h.model.stop()
    await h.model.settled()
    #expect(h.model.level == 0)
  }

  @Test("the recorder failing mid-take stops it, keeps what closed and says so")
  func recorderFailure() async {
    let h = harness()
    h.model.toggle()
    await h.model.settled()
    h.engine.fail()
    #expect(await eventually { h.model.phase == .failed(.stoppedEarly) })
    #expect(h.engine.calls == ["start", "stop"])
  }

  @Test("the running time counts from the start of the take and is zero outside one")
  func elapsed() async {
    let h = harness()
    #expect(h.model.elapsed(at: Date()) == 0)
    h.model.toggle()
    await h.model.settled()
    #expect(h.model.elapsed(at: Date().addingTimeInterval(5)) >= 4.9)
  }

  @Test("every failure has a sentence")
  func failureTexts() {
    let failures: [RecordingPanelModel.Failure] = [
      .notConfigured, .microphoneDenied, .couldNotStart, .nothingRecorded, .stoppedEarly, .lost,
    ]
    #expect(Set(failures.map(RecordingPanelView.text(for:))).count == failures.count)
  }
}

@MainActor
@Suite("Hotkey")
struct HotkeyTests {
  @Test("a press of the key toggles the take through the composition root")
  func pressToggles() async throws {
    let hotkey = FakeTakeHotkey()
    let engine = FakeTakeEngine()
    let root = MacCompositionRoot(
      arguments: [MacCompositionRoot.fakeDataArgument], credentials: InMemoryCredentialStore(),
      poster: RecordingNotificationPoster(), takeEngine: engine, permission: FakeMicrophonePermission(),
      hotkey: hotkey)
    root.installHotkey()
    hotkey.press()
    #expect(await eventually { root.recording.isRecording })
    hotkey.press()
    #expect(await eventually { root.recording.phase == .idle && engine.calls == ["start", "stop"] })
  }

  @Test("the real hotkey registers Control-Option-M by default, not a dictation or input-source key")
  func defaultShortcut() {
    let shortcut = KeyboardShortcutsHotkey.defaultShortcut
    #expect(shortcut.modifiers == [.control, .option])
    #expect(shortcut.carbonKeyCode == 46)  // kVK_ANSI_M
  }
}
