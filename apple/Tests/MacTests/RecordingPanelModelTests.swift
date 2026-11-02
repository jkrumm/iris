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
    access: MicrophoneAccess = .granted, answer: Bool = true, configured: Bool = true, promptHangs: Bool = false,
    deadline: Duration = .seconds(15), permissionDeadline: Duration = .seconds(60)
  ) -> Harness {
    let engine = FakeTakeEngine()
    let permission = FakeMicrophonePermission(access, answer: answer, hangs: promptHangs)
    let model = RecordingPanelModel(
      engine: engine, permission: permission, isConfigured: { configured }, startDeadline: deadline,
      permissionDeadline: permissionDeadline)
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

  @Test("an engine start that never returns ends as a failure at the deadline, and the key works again")
  func stalledEngineStart() async {
    let h = harness(deadline: .milliseconds(50))
    h.engine.hangStart(true)
    h.model.toggle()
    await h.model.settled()
    #expect(h.model.phase == .failed(.couldNotStart))
    #expect(h.engine.calls == ["start", "cancel"])
    h.engine.hangStart(false)
    h.model.toggle()
    await h.model.settled()
    #expect(isRecording(h.model))
  }

  @Test("a permission prompt nobody answers ends as a failure at the deadline, and the key works again")
  func unansweredPermission() async {
    let h = harness(
      access: .undetermined, promptHangs: true, deadline: .milliseconds(50), permissionDeadline: .milliseconds(50))
    h.model.toggle()
    await h.model.settled()
    #expect(h.model.phase == .failed(.couldNotStart))
    #expect(h.engine.calls.isEmpty)  // the engine was never asked, so there is nothing to cancel
    let granted = FakeMicrophonePermission(.granted)
    let again = RecordingPanelModel(engine: h.engine, permission: granted, isConfigured: { true })
    again.toggle()
    await again.settled()
    #expect(again.isRecording)
  }

  @Test("Cancel while starting abandons the start: idle, no take left running, the key starts a new one")
  func cancelWhileStarting() async {
    let h = harness()
    h.engine.hangStart(true)
    h.model.toggle()
    while h.engine.calls.isEmpty { await Task.yield() }  // the engine is stalled in its start
    #expect(h.model.phase == .starting)
    h.model.cancel()
    await h.model.settled()
    #expect(h.model.phase == .idle)
    #expect(h.engine.calls == ["start", "cancel"])
    h.engine.hangStart(false)
    h.model.toggle()
    await h.model.settled()
    #expect(isRecording(h.model))
    #expect(h.engine.calls == ["start", "cancel", "start"])
  }

  @Test("a stalled start that returns late never cancels the next take: the new start waits for the cleanup")
  func lateReturnDoesNotCancelTheNextTake() async {
    let h = harness(deadline: .milliseconds(300))
    h.engine.stallStart(true)
    h.model.toggle()
    while h.model.phase != .failed(.couldNotStart) { await Task.yield() }
    h.engine.stallStart(false)
    h.model.toggle()
    while h.model.phase != .starting { await Task.yield() }
    #expect(h.engine.calls == ["start"])  // the second start waits for the first one's cleanup
    h.engine.releaseStart()
    await h.model.settled()
    #expect(isRecording(h.model))
    #expect(h.engine.calls == ["start", "cancel", "start"])
  }

  @Test("a cleanup that is still pending at the deadline fails the next start visibly instead of starting")
  func pendingCleanupFailsTheNextStart() async {
    let h = harness(deadline: .milliseconds(60))
    h.engine.stallStart(true)
    h.model.toggle()
    while h.model.phase != .failed(.couldNotStart) { await Task.yield() }
    h.model.toggle()
    while h.model.phase != .starting { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(250))  // past the deadline, the cleanup still pending
    #expect(h.model.phase == .failed(.couldNotStart))
    #expect(h.engine.calls == ["start"])
    h.engine.releaseStart()
    await h.model.settled()
    #expect(h.engine.calls == ["start", "cancel"])
  }

  @Test("the permission prompt has its own, longer bound than the engine start")
  func permissionPromptOutlivesTheStartDeadline() async {
    let h = harness(
      access: .undetermined, promptHangs: true, deadline: .milliseconds(40), permissionDeadline: .milliseconds(400))
    h.model.toggle()
    try? await Task.sleep(for: .milliseconds(200))
    #expect(h.model.phase == .starting)  // past the engine deadline, still within the prompt's
    await h.model.settled()
    #expect(h.model.phase == .failed(.couldNotStart))
  }

  @Test("Cancel after the start succeeded but before the panel shows the take drops the take")
  func cancelAfterStartSucceeded() async {
    let h = harness()
    h.engine.holdMicrophones(true)
    h.model.toggle()
    while !h.engine.isHoldingMicrophones { await Task.yield() }
    #expect(h.model.phase == .starting)
    h.model.cancel()
    h.engine.releaseMicrophones()
    await h.model.settled()
    #expect(h.model.phase == .idle)
    #expect(h.engine.calls == ["start", "cancel"])
  }

  @Test("a start that answers within the deadline is unaffected by it")
  func normalStartWithinDeadline() async {
    let h = harness(access: .undetermined, deadline: .milliseconds(500))
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

  @Test("the waveform, the microphone list and the failure watch work in every take, not only the first")
  func theConsumersSurviveTheFirstTake() async {
    let h = harness()
    for round in 1...3 {
      h.model.toggle()
      await h.model.settled()
      let level = Float(round) / 10
      h.engine.level(level)
      #expect(await eventually { h.model.level == level })
      let mics = Microphones(inputs: [FakeAudioDeviceDirectory.usb], current: FakeAudioDeviceDirectory.usb)
      h.engine.setMicrophones(mics)
      #expect(await eventually { h.model.microphones == mics })
      h.engine.setMicrophones(FakeTakeEngine.microphones)
      #expect(await eventually { h.model.microphones == FakeTakeEngine.microphones })
      if round == 3 {
        h.engine.fail()
        #expect(await eventually { h.model.phase == .failed(.stoppedEarly) })
      } else {
        h.model.stop()
        await h.model.settled()
        #expect(h.model.phase == .idle)
        #expect(h.model.level == 0)
      }
    }
  }

  @Test("a take that kept only part of the audio says the recording stopped early")
  func partialTake() async {
    let h = harness()
    h.engine.endStop(with: .partial)
    h.model.toggle()
    await h.model.settled()
    h.model.stop()
    await h.model.settled()
    #expect(h.model.phase == .failed(.stoppedEarly))
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
