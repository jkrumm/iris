import Foundation
import Synchronization

/// Whether a finished memo's reply is spoken on its own while the app is in the foreground (Settings → Spoken replies).
/// Persisted on the device; off until the user turns it on.
nonisolated protocol SpokenRepliesStore: Sendable {
  func load() -> Bool
  func save(_ isOn: Bool)
}

nonisolated struct UserDefaultsSpokenRepliesStore: SpokenRepliesStore {
  static let key = "iris.settings.spokenReplies"
  /// `nil` is the standard domain. A name rather than the `UserDefaults` object, which is not `Sendable`.
  private let suiteName: String?

  init(suiteName: String? = nil) {
    self.suiteName = suiteName
  }

  private var defaults: UserDefaults {
    suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  func load() -> Bool { defaults.bool(forKey: Self.key) }
  func save(_ isOn: Bool) { defaults.set(isOn, forKey: Self.key) }
}

/// Nothing outlives the process: fakes and tests.
nonisolated final class InMemorySpokenRepliesStore: SpokenRepliesStore {
  private let value: Mutex<Bool>

  init(_ isOn: Bool = false) {
    value = Mutex(isOn)
  }

  func load() -> Bool { value.withLock { $0 } }
  func save(_ isOn: Bool) { value.withLock { $0 = isOn } }
}
