import AppKit
import Testing

@testable import IrisMac

@MainActor
@Suite("Mac activation policy")
struct MacActivationPolicyTests {
  private typealias Facts = MacActivationPolicy.WindowFacts

  @Test("no window, or only panels (the popover, the recording panel), keeps the app out of the Dock and ⌘Tab")
  func accessory() {
    #expect(MacActivationPolicy.policy(for: []) == .accessory)
    let panel = Facts(isVisible: true, isTitled: false, canBecomeMain: false)
    let hidden = Facts(isVisible: false, isTitled: true, canBecomeMain: true)
    #expect(MacActivationPolicy.policy(for: [panel, hidden]) == .accessory)
  }

  @Test("a visible titled window that can be main makes the app regular")
  func regular() {
    let window = Facts(isVisible: true, isTitled: true, canBecomeMain: true)
    let panel = Facts(isVisible: true, isTitled: false, canBecomeMain: false)
    #expect(MacActivationPolicy.policy(for: [panel, window]) == .regular)
  }

  @Test("a Dock click always ends on the main window; only a first run opens the onboarding instead")
  func reopen() {
    #expect(MacActivationPolicy.reopenAction(mainWindowOpen: false, needsOnboarding: false) == .openMain)
    #expect(MacActivationPolicy.reopenAction(mainWindowOpen: true, needsOnboarding: false) == .raiseMain)
    #expect(MacActivationPolicy.reopenAction(mainWindowOpen: false, needsOnboarding: true) == .openOnboarding)
    #expect(MacActivationPolicy.reopenAction(mainWindowOpen: true, needsOnboarding: true) == .openOnboarding)
  }

  @Test(
    "a visible Settings window is not the main window: the Dock click still opens it, and the root tells which is open")
  func reopenBesideSettings() {
    let root = MacCompositionRoot(arguments: [MacCompositionRoot.fakeDataArgument])
    root.showSettings(source: "test")
    #expect(!root.isWindowOpen)
    let action = MacActivationPolicy.reopenAction(
      mainWindowOpen: root.isWindowOpen, needsOnboarding: root.needsOnboarding)
    #expect(action == .openMain)
    let before = root.windowRequest
    root.showMainWindow(source: "dock")
    #expect(root.windowRequest == before + 1)
    root.windowDidAppear()
    #expect(
      MacActivationPolicy.reopenAction(mainWindowOpen: root.isWindowOpen, needsOnboarding: root.needsOnboarding)
        == .raiseMain)
  }

  @Test("a launch by the user opens the main window, a login launch and a first run do not")
  func launchOrigin() {
    #expect(MacLaunchOrigin(loginItem: false) == .user)
    #expect(MacLaunchOrigin(loginItem: true) == .loginItem)
    #expect(MacLaunchOrigin.user.opensMainWindow(needsOnboarding: false))
    #expect(!MacLaunchOrigin.user.opensMainWindow(needsOnboarding: true))
    #expect(!MacLaunchOrigin.loginItem.opensMainWindow(needsOnboarding: false))
    #expect(!MacLaunchOrigin.loginItem.opensMainWindow(needsOnboarding: true))
  }
}
