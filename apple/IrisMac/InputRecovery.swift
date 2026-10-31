import Foundation
import IrisCapture
import Synchronization
import os

/// The system default input a Mac take replaced, written down before it was replaced: a kill mid-take must not leave the
/// microphone the user picked in the panel as the Mac's input for good (TDD §5).
nonisolated struct InputRecovery: Codable, Equatable, Sendable {
  /// The default input before the first pick of the take: what a restore puts back.
  var original: String
  /// The device the take made the default last: a restore applies only while this is still the default.
  var chosen: String
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

  init(_ inner: any RouteManager, store: any InputRecoveryStore) {
    self.inner = inner
    self.store = store
  }

  nonisolated var routeChanges: AsyncStream<RouteChange> { inner.routeChanges }

  func currentRoute() async -> RouteSnapshot { await inner.currentRoute() }

  func rules() async -> [String: String] { await inner.rules() }

  func setRule(fingerprint: String, preferredPortUID: String?) async {
    await inner.setRule(fingerprint: fingerprint, preferredPortUID: preferredPortUID)
  }

  func setPreferredInput(uid: String?) async throws {
    guard let uid else {
      // A restore that threw keeps the record: the launch recovery tries again. One that ran (or had nothing to do) ends it.
      try await inner.setPreferredInput(uid: nil)
      store.clear()
      return
    }
    let before = await inner.currentRoute().currentInput?.uid
    let existing = store.load()
    // Already the default: the inner manager changes nothing and remembers no original, so there is nothing to write down.
    if let before, before != uid {
      store.save(InputRecovery(original: existing?.original ?? before, chosen: uid))
    }
    do {
      try await inner.setPreferredInput(uid: uid)
    } catch {
      // Nothing changed: put the record back as it was.
      if let existing { store.save(existing) } else { store.clear() }
      throw error
    }
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
  }

  /// Run once at launch, before the first take: an earlier run killed mid-take left its picked microphone as the system
  /// default. Puts the original back, but only while the default is still the device that run set (a default somebody else
  /// chose since is left alone) and the original is still attached.
  @discardableResult
  static func recover(store: any InputRecoveryStore, directory: any AudioDeviceDirectory) -> Recovery {
    guard let record = store.load() else { return .none }
    guard directory.defaultInput()?.uid == record.chosen, record.chosen != record.original,
      directory.inputs().contains(where: { $0.uid == record.original })
    else {
      store.clear()
      return .dropped
    }
    do {
      try directory.setDefaultInput(uid: record.original)
      store.clear()
      return .restored
    } catch {
      Logger(subsystem: "com.jkrumm.iris", category: "capture")
        .error("the input of a killed take was not restored: \(String(describing: error), privacy: .public)")
      return .failed
    }
  }
}
