import AppKit
import Testing

@testable import IrisMac

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
}
