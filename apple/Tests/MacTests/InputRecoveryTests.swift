import Foundation
import IrisCapture
import Testing

@testable import IrisMac

/// The original default input survives a kill: the wrapper writes it down before a pick, `recover` puts it back at launch.
@Suite("Mac input recovery")
struct InputRecoveryTests {
  private let builtIn = FakeAudioDeviceDirectory.builtIn
  private let usb = FakeAudioDeviceDirectory.usb

  private func rig() -> (devices: FakeAudioDeviceDirectory, store: InMemoryInputRecoveryStore, routes: RecoveringRouteManager)
  {
    let devices = FakeAudioDeviceDirectory()
    let store = InMemoryInputRecoveryStore()
    let inner = DirectoryRouteManager(directory: devices, suiteName: "iris.mac.tests.\(UUID().uuidString)")
    return (devices, store, RecoveringRouteManager(inner, store: store))
  }

  @Test("a pick writes the original down before it changes the default")
  func pickRecordsTheOriginal() async throws {
    let (devices, store, routes) = rig()
    try await routes.setPreferredInput(uid: usb.uid)
    #expect(devices.defaultInput()?.uid == usb.uid)
    #expect(store.load() == InputRecovery(original: builtIn.uid, chosen: usb.uid))
  }

  @Test("a second pick keeps the first original")
  func secondPickKeepsTheOriginal() async throws {
    let (devices, store, routes) = rig()
    try await routes.setPreferredInput(uid: usb.uid)
    try await routes.setPreferredInput(uid: builtIn.uid)
    #expect(devices.defaultInput()?.uid == builtIn.uid)
    #expect(store.load() == InputRecovery(original: builtIn.uid, chosen: builtIn.uid))
  }

  @Test("the restore at the end of a take clears the record")
  func restoreClearsTheRecord() async throws {
    let (devices, store, routes) = rig()
    try await routes.setPreferredInput(uid: usb.uid)
    try await routes.setPreferredInput(uid: nil)
    #expect(devices.defaultInput()?.uid == builtIn.uid)
    #expect(store.load() == nil)
  }

  @Test("picking the default that is already set writes nothing")
  func samePickWritesNothing() async throws {
    let (_, store, routes) = rig()
    try await routes.setPreferredInput(uid: builtIn.uid)
    #expect(store.load() == nil)
  }

  @Test("a pick that throws leaves no record behind")
  func failedPickLeavesNoRecord() async {
    let (devices, store, routes) = rig()
    devices.failSetting("denied")
    await #expect(throws: CaptureError.self) { try await routes.setPreferredInput(uid: usb.uid) }
    #expect(store.load() == nil)
    #expect(devices.defaultInput()?.uid == builtIn.uid)
  }

  @Test("a kill mid-take: the next launch puts the original input back")
  func launchRestoresAfterAKill() async throws {
    let (devices, store, routes) = rig()
    try await routes.setPreferredInput(uid: usb.uid)
    // The process dies here: a new run has the device list and the store, nothing else.
    #expect(RecoveringRouteManager.recover(store: store, directory: devices) == .restored)
    #expect(devices.defaultInput()?.uid == builtIn.uid)
    #expect(store.load() == nil)
  }

  @Test("a default somebody else chose since is left alone")
  func launchLeavesSomebodyElsesChoice() async throws {
    let (devices, store, routes) = rig()
    try await routes.setPreferredInput(uid: usb.uid)
    let other = InputPort(uid: "fake-mac-other", name: "Other", kind: .other)
    devices.setDevices([builtIn, usb, other])
    try devices.setDefaultInput(uid: other.uid)
    #expect(RecoveringRouteManager.recover(store: store, directory: devices) == .dropped)
    #expect(devices.defaultInput()?.uid == other.uid)
    #expect(store.load() == nil)
  }

  @Test("the original device is gone: the record is dropped")
  func launchDropsWhenTheOriginalIsGone() async throws {
    let (devices, store, routes) = rig()
    try await routes.setPreferredInput(uid: usb.uid)
    devices.setDevices([usb])
    #expect(RecoveringRouteManager.recover(store: store, directory: devices) == .dropped)
    #expect(store.load() == nil)
  }

  @Test("a restore that fails keeps the record for the next launch")
  func failedRestoreKeepsTheRecord() async throws {
    let (devices, store, routes) = rig()
    try await routes.setPreferredInput(uid: usb.uid)
    devices.failSetting("busy")
    #expect(RecoveringRouteManager.recover(store: store, directory: devices) == .failed)
    #expect(store.load() != nil)
    devices.failSetting(nil)
    #expect(RecoveringRouteManager.recover(store: store, directory: devices) == .restored)
  }

  @Test("no record, nothing to do")
  func launchWithoutRecord() {
    let (devices, store, _) = rig()
    #expect(RecoveringRouteManager.recover(store: store, directory: devices) == .none)
  }

  @Test("the UserDefaults store round-trips a record")
  func userDefaultsRoundTrip() {
    let store = UserDefaultsInputRecoveryStore(suiteName: "iris.mac.tests.\(UUID().uuidString)")
    #expect(store.load() == nil)
    store.save(InputRecovery(original: "a", chosen: "b"))
    #expect(store.load() == InputRecovery(original: "a", chosen: "b"))
    store.clear()
    #expect(store.load() == nil)
  }
}
