import Foundation
import Testing

@testable import IrisMac

/// The menu items' view model on the scripted engine: no Sparkle, no network, no window.
@MainActor
@Suite("Mac updater")
struct UpdaterTests {
  @Test("starts from the engine's availability")
  func startsFromEngine() {
    #expect(Updater(engine: ScriptedUpdateEngine(canCheckForUpdates: true)).canCheckForUpdates)
    #expect(!Updater(engine: ScriptedUpdateEngine(canCheckForUpdates: false)).canCheckForUpdates)
  }

  @Test("a check goes to the engine")
  func checkForwards() {
    let engine = ScriptedUpdateEngine()
    let updater = Updater(engine: engine)
    updater.checkForUpdates()
    #expect(engine.checks == 1)
  }

  @Test("no check starts while the engine is busy")
  func busyEngineIsNotAsked() {
    let engine = ScriptedUpdateEngine(canCheckForUpdates: false)
    let updater = Updater(engine: engine)
    updater.checkForUpdates()
    #expect(engine.checks == 0)
  }

  @Test("availability follows the engine through a check")
  func followsEngine() {
    let engine = ScriptedUpdateEngine()
    let updater = Updater(engine: engine)
    engine.canCheckForUpdates = false
    #expect(!updater.canCheckForUpdates)
    updater.checkForUpdates()
    #expect(engine.checks == 0)
    engine.canCheckForUpdates = true
    #expect(updater.canCheckForUpdates)
    updater.checkForUpdates()
    #expect(engine.checks == 1)
  }

  @Test("the fake composition has no updater")
  func fakeLaunchHasNone() {
    let root = MacCompositionRoot(arguments: [MacCompositionRoot.fakeDataArgument])
    #expect(root.updater == nil)
  }

  @Test("an engine given to the root becomes its updater")
  func rootOwnsUpdater() {
    let engine = ScriptedUpdateEngine()
    let root = MacCompositionRoot(
      arguments: [MacCompositionRoot.fakeDataArgument], updateEngine: engine)
    root.updater?.checkForUpdates()
    #expect(engine.checks == 1)
  }
}
