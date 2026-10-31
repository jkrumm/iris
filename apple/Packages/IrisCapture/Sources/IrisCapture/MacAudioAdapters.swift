#if os(macOS)
  import CoreAudio
  import Foundation

  // The Mac's side of the capture ports. macOS has no `AVAudioSession`: the engine records from the system default input device,
  // so "the route" is the Core Audio device list and "select a microphone" is the default input. The decisions (what a switch
  // remembers, what restoring means) live in `DirectoryRouteManager`, over a port, so they are tested without hardware.

  /// macOS has no shared audio session to configure, activate or interrupt: every call succeeds and nothing is delivered.
  public struct MacAudioSessionController: AudioSessionController {
    public let interruptions = AsyncStream<InterruptionEvent> { _ in }

    public init() {}

    public func configure() async throws {}
    public func activate() async throws {}
    public func deactivate() async throws {}
  }

  /// The Core Audio device list, as the route manager needs it.
  /// Production: `CoreAudioDeviceDirectory`. Fake: `FakeAudioDeviceDirectory`.
  public protocol AudioDeviceDirectory: Sendable {
    /// Every visible device that can record, in the order Core Audio lists them.
    func inputs() -> [InputPort]
    /// The system default input, `nil` when the Mac has none.
    func defaultInput() -> InputPort?
    /// The system default output: its UID and name.
    func defaultOutput() -> (uid: String, name: String)?
    /// Makes this device the system default input.
    func setDefaultInput(uid: String) throws
    /// Yields when the device list or a default changes. One consumer.
    var changes: AsyncStream<Void> { get }
  }

  /// `RouteManager` over the device list: the available inputs are the recording devices, the current input is the default one,
  /// and choosing a microphone sets the default input. The default that was there before the first choice is kept, so
  /// `setPreferredInput(uid: nil)` puts it back: a take must not leave the Mac's input changed for the next call.
  public actor DirectoryRouteManager: RouteManager {
    public nonisolated let routeChanges: AsyncStream<RouteChange>
    private let directory: any AudioDeviceDirectory
    private let defaults: UserDefaults
    /// The default input before the first choice of a take, until it is restored.
    private var originalDefault: String?
    private static let rulesKey = "com.jkrumm.iris.capture.routeRules"

    /// - Parameter suiteName: the `UserDefaults` suite the rules live in; `nil` is the app's own.
    public init(directory: any AudioDeviceDirectory, suiteName: String? = nil) {
      self.directory = directory
      defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
      let changes = directory.changes
      routeChanges = AsyncStream { continuation in
        // Owned by the stream; ends when the directory's stream does or the consumer goes away.
        let forwarding = Task {
          for await _ in changes {
            continuation.yield(RouteChange(snapshot: Self.snapshot(of: directory), reason: .other))
          }
          continuation.finish()
        }
        continuation.onTermination = { _ in forwarding.cancel() }
      }
    }

    public func currentRoute() -> RouteSnapshot { Self.snapshot(of: directory) }

    public func setPreferredInput(uid: String?) throws {
      guard let uid else {
        try restoreOriginal()
        return
      }
      let current = directory.defaultInput()
      guard directory.inputs().contains(where: { $0.uid == uid }) else { throw CaptureError.inputUnavailable(uid: uid) }
      guard current?.uid != uid else { return }
      try setDefault(uid)
      if originalDefault == nil { originalDefault = current?.uid }
    }

    private func setDefault(_ uid: String) throws {
      do {
        try directory.setDefaultInput(uid: uid)
      } catch let error as CaptureError {
        throw error
      } catch {
        throw CaptureError.sessionFailure(String(describing: error))
      }
    }

    /// Puts the kept default back, when it is still there. Nothing kept: nothing to do.
    private func restoreOriginal() throws {
      guard let original = originalDefault else { return }
      originalDefault = nil
      guard directory.defaultInput()?.uid != original, directory.inputs().contains(where: { $0.uid == original }) else {
        return
      }
      try setDefault(original)
    }

    public func rules() -> [String: String] {
      defaults.dictionary(forKey: Self.rulesKey) as? [String: String] ?? [:]
    }

    public func setRule(fingerprint: String, preferredPortUID: String?) {
      var current = rules()
      current[fingerprint] = preferredPortUID
      defaults.set(current, forKey: Self.rulesKey)
    }

    private static func snapshot(of directory: any AudioDeviceDirectory) -> RouteSnapshot {
      let output = directory.defaultOutput()
      return RouteSnapshot(
        availableInputs: directory.inputs(), currentInput: directory.defaultInput(),
        outputUIDs: output.map { [$0.uid] } ?? [], outputNames: output.map { [$0.name] } ?? [])
    }
  }

  extension PortKind {
    /// By Core Audio transport type (`kAudioDeviceTransportType*`, four-character codes).
    init(transportType: UInt32) {
      switch transportType {
      case kAudioDeviceTransportTypeBuiltIn: self = .builtInMic
      case kAudioDeviceTransportTypeBluetooth: self = .bluetoothHFP
      case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
      case kAudioDeviceTransportTypeUSB: self = .usb
      default: self = .other
      }
    }
  }

  /// Production directory over Core Audio's hardware object. Thin on purpose: only compile-checked and smoke-run on the mini
  /// (which may have no input at all); a real microphone is the owner's MacBook (`docs/spikes/device-checklist.md`).
  public final class CoreAudioDeviceDirectory: AudioDeviceDirectory {
    public let changes: AsyncStream<Void>
    private let listeners: [Listener]

    private struct Listener: @unchecked Sendable {
      var address: AudioObjectPropertyAddress
      let block: AudioObjectPropertyListenerBlock
    }

    public init() {
      let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
      changes = stream
      let selectors = [
        kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
      ]
      listeners = selectors.map { selector in
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in continuation.yield() }
        AudioObjectAddPropertyListenerBlock(
          AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        return Listener(address: address, block: block)
      }
    }

    deinit {
      for var listener in listeners {
        AudioObjectRemovePropertyListenerBlock(
          AudioObjectID(kAudioObjectSystemObject), &listener.address, DispatchQueue.main, listener.block)
      }
    }

    public func inputs() -> [InputPort] {
      Self.deviceIDs().compactMap { id in
        guard Self.hasInput(id), !Self.isHidden(id) else { return nil }
        return Self.port(id)
      }
    }

    public func defaultInput() -> InputPort? {
      Self.deviceID(of: kAudioHardwarePropertyDefaultInputDevice).flatMap(Self.port)
    }

    public func defaultOutput() -> (uid: String, name: String)? {
      guard let id = Self.deviceID(of: kAudioHardwarePropertyDefaultOutputDevice),
        let uid = Self.string(id, kAudioDevicePropertyDeviceUID)
      else { return nil }
      return (uid, Self.string(id, kAudioObjectPropertyName) ?? uid)
    }

    public func setDefaultInput(uid: String) throws {
      guard let id = Self.deviceIDs().first(where: { Self.string($0, kAudioDevicePropertyDeviceUID) == uid }) else {
        throw CaptureError.inputUnavailable(uid: uid)
      }
      var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
      var device = id
      let status = AudioObjectSetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &device)
      guard status == noErr else {
        throw CaptureError.sessionFailure("the default input was not set (OSStatus \(status))")
      }
    }

    // MARK: Core Audio

    private static func address(
      _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
      AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
      var address = address(kAudioHardwarePropertyDevices)
      let system = AudioObjectID(kAudioObjectSystemObject)
      var size: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
      var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
      guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
      return ids
    }

    private static func deviceID(of selector: AudioObjectPropertySelector) -> AudioDeviceID? {
      var address = address(selector)
      var id = AudioDeviceID(kAudioObjectUnknown)
      var size = UInt32(MemoryLayout<AudioDeviceID>.size)
      guard
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
        id != kAudioObjectUnknown
      else { return nil }
      return id
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
      var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
      var size: UInt32 = 0
      return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func isHidden(_ id: AudioDeviceID) -> Bool {
      var address = address(kAudioDevicePropertyIsHidden)
      var hidden: UInt32 = 0
      var size = UInt32(MemoryLayout<UInt32>.size)
      return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &hidden) == noErr && hidden != 0
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
      var address = address(selector)
      var value: Unmanaged<CFString>?
      var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
      guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
      return value?.takeRetainedValue() as String?
    }

    private static func port(_ id: AudioDeviceID) -> InputPort? {
      guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
      var address = address(kAudioDevicePropertyTransportType)
      var transport: UInt32 = 0
      var size = UInt32(MemoryLayout<UInt32>.size)
      _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
      return InputPort(
        uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid, kind: PortKind(transportType: transport))
    }
  }

  /// A scripted device list for tests and `-IrisFakeData`: nothing touches Core Audio.
  public final class FakeAudioDeviceDirectory: AudioDeviceDirectory, @unchecked Sendable {
    public static let builtIn = InputPort(uid: "fake-mac-builtin", name: "MacBook Microphone", kind: .builtInMic)
    public static let usb = InputPort(uid: "fake-mac-usb", name: "USB Microphone", kind: .usb)

    public let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var devices: [InputPort]
    private var current: String?
    private var failure: String?

    public init(inputs: [InputPort] = [FakeAudioDeviceDirectory.builtIn, FakeAudioDeviceDirectory.usb]) {
      (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
      devices = inputs
      current = inputs.first?.uid
    }

    public func inputs() -> [InputPort] { lock.withLock { devices } }
    public func defaultInput() -> InputPort? { lock.withLock { devices.first { $0.uid == current } } }
    public func defaultOutput() -> (uid: String, name: String)? { ("fake-mac-speakers", "MacBook Speakers") }

    public func setDefaultInput(uid: String) throws {
      try lock.withLock {
        if let failure { throw CaptureError.sessionFailure(failure) }
        current = uid
      }
      continuation.yield()
    }

    /// Script hook: the next `setDefaultInput` throws.
    public func failSetting(_ reason: String?) { lock.withLock { failure = reason } }

    /// Script hook: a device appears or goes; the default falls back to the first one that is left.
    public func setDevices(_ inputs: [InputPort]) {
      lock.withLock {
        devices = inputs
        if !inputs.contains(where: { $0.uid == current }) { current = inputs.first?.uid }
      }
      continuation.yield()
    }
  }
#endif
