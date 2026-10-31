import AppKit
import Foundation
import Testing

@testable import IrisMac

/// The recording panel can take the keys without becoming the active app and without taking them when it is shown.
@MainActor
@Suite("Recording panel key behaviour")
struct RecordingPanelKeyTests {
  private func shownPanel() async -> (RecordingPanelController, RecordingPanelModel, NSPanel) {
    let model = RecordingPanelModel(
      engine: FakeTakeEngine(), permission: FakeMicrophonePermission(.granted), isConfigured: { true })
    let controller = RecordingPanelController(model: model)
    model.toggle()
    await model.settled()
    return (controller, model, controller.panel ?? NSPanel())
  }

  @Test("the panel is non-activating, may become key, never main, and is not key-only-if-needed")
  func configuration() async throws {
    let (_, model, panel) = await shownPanel()
    defer { model.cancel() }
    #expect(panel is NonActivatingPanel)
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.canBecomeKey)
    #expect(!panel.canBecomeMain)
    #expect(!panel.becomesKeyOnlyIfNeeded)
    #expect(panel.isFloatingPanel && !panel.hidesOnDeactivate)
  }

  @Test("showing the panel does not make it key and does not move the frontmost app")
  func showingDoesNotTakeTheKeys() async {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let (_, model, panel) = await shownPanel()
    defer { model.cancel() }
    #expect(panel.isVisible)
    #expect(!panel.isKeyWindow)
    #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == front)
  }

  /// Verified on the mini (macOS 26, Chrome in front): `makeKey()` makes the panel key and the frontmost application stays
  /// Chrome. `NSApp.isActive` reads `true` afterwards, which the research report said it would not; whether the *keystrokes*
  /// then reach the panel, and the app behind it stops getting them, only a person at a MacBook can show (device-checklist Mac row).
  @Test("making the panel key (a click) leaves the frontmost application as it was")
  func keyDoesNotMoveTheFrontmostApp() async {
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let (_, model, panel) = await shownPanel()
    defer { model.cancel() }
    panel.makeKey()
    #expect(panel.isKeyWindow)
    #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == front)
  }
}
