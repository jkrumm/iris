#if os(macOS)
  import CoreAudio
  import Foundation
  import Testing

  @testable import IrisCapture

  struct MacAudioAdaptersTests {
    private func manager(
      inputs: [InputPort] = [FakeAudioDeviceDirectory.builtIn, FakeAudioDeviceDirectory.usb]
    ) -> (DirectoryRouteManager, FakeAudioDeviceDirectory) {
      let directory = FakeAudioDeviceDirectory(inputs: inputs)
      return (DirectoryRouteManager(directory: directory, suiteName: "iris.tests.\(UUID().uuidString)"), directory)
    }

    @Test func routeIsTheDeviceListWithTheDefaultAsCurrentInput() async {
      let (routes, _) = manager()
      let route = await routes.currentRoute()
      #expect(route.availableInputs.map(\.uid) == ["fake-mac-builtin", "fake-mac-usb"])
      #expect(route.currentInput?.uid == "fake-mac-builtin")
      #expect(route.outputUIDs == ["fake-mac-speakers"])
      #expect(route.fingerprint == "fake-mac-speakers")
    }

    @Test func choosingAMicrophoneSetsTheDefaultAndNilPutsTheOriginalBack() async throws {
      let (routes, directory) = manager()
      try await routes.setPreferredInput(uid: "fake-mac-usb")
      #expect(directory.defaultInput()?.uid == "fake-mac-usb")
      try await routes.setPreferredInput(uid: "fake-mac-builtin")  // a second choice keeps the first original
      try await routes.setPreferredInput(uid: "fake-mac-usb")
      try await routes.setPreferredInput(uid: nil)
      #expect(directory.defaultInput()?.uid == "fake-mac-builtin")
    }

    @Test func restoringWithoutAChoiceChangesNothing() async throws {
      let (routes, directory) = manager()
      try await routes.setPreferredInput(uid: nil)
      #expect(directory.defaultInput()?.uid == "fake-mac-builtin")
    }

    @Test func anUnknownMicrophoneIsRefused() async {
      let (routes, directory) = manager()
      await #expect(throws: CaptureError.inputUnavailable(uid: "gone")) {
        try await routes.setPreferredInput(uid: "gone")
      }
      #expect(directory.defaultInput()?.uid == "fake-mac-builtin")
    }

    @Test func aFailedSwitchKeepsNoOriginalToRestore() async throws {
      let (routes, directory) = manager()
      directory.failSetting("denied")
      await #expect(throws: CaptureError.sessionFailure("denied")) {
        try await routes.setPreferredInput(uid: "fake-mac-usb")
      }
      directory.failSetting(nil)
      try await routes.setPreferredInput(uid: nil)
      #expect(directory.defaultInput()?.uid == "fake-mac-builtin")
    }

    @Test func theKeptOriginalIsNotRestoredOnceItIsUnplugged() async throws {
      let (routes, directory) = manager()
      try await routes.setPreferredInput(uid: "fake-mac-usb")
      directory.setDevices([FakeAudioDeviceDirectory.usb])
      try await routes.setPreferredInput(uid: nil)
      #expect(directory.defaultInput()?.uid == "fake-mac-usb")
    }

    @Test func aDeviceChangeIsARouteChange() async {
      let (routes, directory) = manager()
      var changes = routes.routeChanges.makeAsyncIterator()
      directory.setDevices([FakeAudioDeviceDirectory.usb])
      let change = await changes.next()
      #expect(change?.snapshot.availableInputs.map(\.uid) == ["fake-mac-usb"])
      #expect(change?.snapshot.currentInput?.uid == "fake-mac-usb")
    }

    @Test func rulesArePerFingerprintAndPersist() async {
      let (routes, _) = manager()
      await routes.setRule(fingerprint: "fake-mac-speakers", preferredPortUID: "fake-mac-usb")
      #expect(await routes.rules() == ["fake-mac-speakers": "fake-mac-usb"])
      await routes.setRule(fingerprint: "fake-mac-speakers", preferredPortUID: nil)
      #expect(await routes.rules().isEmpty)
    }

    @Test func transportTypesMapToPortKinds() {
      #expect(PortKind(transportType: kAudioDeviceTransportTypeBuiltIn) == .builtInMic)
      #expect(PortKind(transportType: kAudioDeviceTransportTypeBluetooth) == .bluetoothHFP)
      #expect(PortKind(transportType: kAudioDeviceTransportTypeBluetoothLE) == .bluetoothLE)
      #expect(PortKind(transportType: kAudioDeviceTransportTypeUSB) == .usb)
      #expect(PortKind(transportType: kAudioDeviceTransportTypeVirtual) == .other)
    }

    @Test func theSessionControllerAcceptsEveryCall() async throws {
      let session = MacAudioSessionController()
      try await session.configure()
      try await session.activate()
      try await session.deactivate()
    }

    /// The mini may have no microphone at all: the real directory must answer, with whatever it has.
    @Test func theCoreAudioDirectoryAnswersOnThisMachine() {
      let directory = CoreAudioDeviceDirectory()
      let inputs = directory.inputs()
      #expect(inputs.allSatisfy { !$0.uid.isEmpty })
      if let current = directory.defaultInput() { #expect(!current.uid.isEmpty) }
    }
  }
#endif
