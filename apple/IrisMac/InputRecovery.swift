import Foundation
import IrisCapture
import Synchronization

/// The system default input a Mac take replaced, written down before it was replaced: a kill mid-take must not leave the
/// microphone the user picked in the panel as the Mac's input for good (TDD §5).
nonisolated struct InputRecovery: Codable, Equatable, Sendable {
  /// The default input before the first pick of the take: what a restore puts back.
  var original: String
  /// The device the take is making the default (the switch in progress, or the last one done): a restore applies only while it,
  /// or ``replaced``, is still the default.
  var chosen: String
  /// The default that ``chosen`` replaces. The record is written before the switch, so a kill can leave either of the two as
  /// the default; `nil` in a record written before this field existed.
  var replaced: String?

  init(original: String, chosen: String, replaced: String? = nil) {
    self.original = original
    self.chosen = chosen
    self.replaced = replaced
  }
}

/// Where ``InputRecovery`` is kept. Production: `UserDefaults`. Tests: in memory.
nonisolated protocol InputRecoveryStore: Sendable {
  func load() -> InputRecovery?
  func save(_ recovery: InputRecovery)
  func clear()
}

nonisolated struct UserDefaultsInputRecoveryStore: InputRecoveryStore {
  private static let key = "com.jkrumm.iris.mac.inputRecovery"
  /// `nil` is the app's own defaults; a name keeps a test run away from the real install.
  let suiteName: String?

  init(suiteName: String? = nil) {
    self.suiteName = suiteName
  }

  private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

  func load() -> InputRecovery? {
    defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(InputRecovery.self, from: $0) }
  }

  func save(_ recovery: InputRecovery) {
    guard let data = try? JSONEncoder().encode(recovery) else { return }
    defaults.set(data, forKey: Self.key)
    // The write must be on disk before the call that changes the Mac's input: the kill this guards against is not graceful.
    defaults.synchronize()
  }

  func clear() {
    defaults.removeObject(forKey: Self.key)
    defaults.synchronize()
  }
}

nonisolated final class InMemoryInputRecoveryStore: InputRecoveryStore {
  private let state = Mutex<InputRecovery?>(nil)

  func load() -> InputRecovery? { state.withLock { $0 } }
  func save(_ recovery: InputRecovery) { state.withLock { $0 = recovery } }
  func clear() { state.withLock { $0 = nil } }
}

/// A `RouteManager` that writes the original default input down before a pick changes it, and forgets it once the restore
/// has run. It wraps ``DirectoryRouteManager`` (read-only, in `IrisCapture`), whose own memory of the original is in-process.
///
/// The record is written **before** the input is changed, so a kill between the two leaves a record whose `chosen` is not the
/// default: ``recover(store:directory:)`` finds nothing to undo and drops it.
actor RecoveringRouteManager: RouteManager {
  private let inner: any RouteManager
  private let store: any InputRecoveryStore
  private let events: any CaptureEvents
  /// This process changed the default input and has not put it back: the inner manager remembers an original to restore. A
  /// record left by an earlier run (a recovery that failed or is waiting for a device) is not this process's to clear.
  private var changedByThisProcess = false

  init(_ inner: any RouteManager, store: any InputRecoveryStore, events: any CaptureEvents = NoCaptureEvents()) {
    self.inner = inner
    self.store = store
    self.events = events
  }

  nonisolated var routeChanges: AsyncStream<RouteChange> { inner.routeChanges }

  func currentRoute() async -> RouteSnapshot { await inner.currentRoute() }

  func rules() async -> [String: String] { await inner.rules() }

  func setRule(fingerprint: String, preferredPortUID: String?) async {
    await inner.setRule(fingerprint: fingerprint, preferredPortUID: preferredPortUID)
  }

  func setPreferredInput(uid: String?) async throws {
    guard let uid else {
      // The inner manager restores what this process changed. A restore that threw keeps the record (the launch recovery tries
      // again), and so does a take that changed nothing: a record from an earlier run is only ended by its own recovery.
      let owned = changedByThisProcess
      changedByThisProcess = false
      do {
        try await inner.setPreferredInput(uid: nil)
      } catch {
        events.event("audio.input_switch", memoID: nil, error: true, ["action": "restore", "ok": false])
        throw error
      }
      if owned { store.clear() }
      events.event("audio.input_switch", ["action": "restore", "ok": true])
      return
    }
    let before = await inner.currentRoute().currentInput?.uid
    let existing = store.load()
    // Already the default: the inner manager changes nothing and remembers no original, so there is nothing to write down.
    if let before, before != uid {
      store.save(InputRecovery(original: existing?.original ?? before, chosen: uid, replaced: before))
    }
    do {
      try await inner.setPreferredInput(uid: uid)
    } catch {
      // Nothing changed: put the record back as it was.
      if let existing { store.save(existing) } else { store.clear() }
      events.event("audio.input_switch", memoID: nil, error: true, ["action": "pick", "ok": false])
      throw error
    }
    if before != nil, before != uid { changedByThisProcess = true }
    // No device id or name in the record: the action and the outcome are what a trace needs.
    events.event("audio.input_switch", ["action": "pick", "ok": true])
  }

  /// What launch did about a record left by an earlier run.
  enum Recovery: Equatable {
    /// No record.
    case none
    /// The record was stale (the default is no longer the pick, or the old device is gone) and was dropped.
    case dropped
    /// The original input is the default again.
    case restored
    /// The restore failed; the record stays for the next launch.
    case failed
    /// The default is still one of the switch's two sides but the original is not attached yet (a USB or Bluetooth microphone
    /// that comes up after login): the record stays for the next launch.
    case pending
  }

  /// Run once at launch, before the first take: an earlier run killed mid-take left its picked microphone as the system
  /// default. Puts the original back, but only while the default is one of the two sides of the switch the record was written
  /// for (the device being set, or the one it replaced: a kill can land either side of the system call; a default somebody
  /// else chose since is left alone) and the original is attached; one that is not attached yet keeps the record (`pending`).
  @discardableResult
  static func recover(store: any InputRecoveryStore, directory: any AudioDeviceDirectory) -> Recovery {
    guard let record = store.load() else { return .none }
    let current = directory.defaultInput()?.uid
    let interrupted = current == record.chosen || (record.replaced != nil && current == record.replaced)
    guard interrupted, current != record.original else {
      store.clear()
      return .dropped
    }
    // The original may simply not be enumerated yet: dropping the record then would leave the wrong default for good.
    guard directory.inputs().contains(where: { $0.uid == record.original }) else { return .pending }
    do {
      try directory.setDefaultInput(uid: record.original)
      store.clear()
      return .restored
    } catch {
      // Not logged here: the error can name a port, and the outcome is the `audio.input_recovery` record the caller writes.
      return .failed
    }
  }
}

extension RecoveringRouteManager.Recovery {
  /// For the device log (`audio.input_recovery`).
  var telemetryName: String {
    switch self {
    case .none: "none"
    case .dropped: "dropped"
    case .restored: "restored"
    case .failed: "failed"
    case .pending: "pending"
    }
  }
}
