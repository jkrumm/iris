import Foundation
import Synchronization

/// The ids of the memos History keeps out of the list while their server `DELETE` is pending (a cancelled take, a
/// discarded queue row). Persisted, so a relaunch before the delete settles does not bring the memo back.
nonisolated protocol HiddenMemoStore: Sendable {
  func load() -> Set<String>
  func save(_ ids: Set<String>)
}

/// `UserDefaults`: a handful of ids, read once at launch and written on each change.
nonisolated struct UserDefaultsHiddenMemoStore: HiddenMemoStore {
  static let key = "iris.history.hiddenMemoIDs"
  /// `nil` is the standard domain. A name rather than the `UserDefaults` object, which is not `Sendable`.
  private let suiteName: String?

  init(suiteName: String? = nil) {
    self.suiteName = suiteName
  }

  private var defaults: UserDefaults {
    suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
  }

  func load() -> Set<String> {
    Set(defaults.stringArray(forKey: Self.key) ?? [])
  }

  func save(_ ids: Set<String>) {
    if ids.isEmpty {
      defaults.removeObject(forKey: Self.key)
    } else {
      defaults.set(ids.sorted(), forKey: Self.key)
    }
  }
}

/// Nothing outlives the process: fakes (`-IrisFakeCapture` starts clean every launch) and tests.
nonisolated final class InMemoryHiddenMemoStore: HiddenMemoStore {
  private let ids: Mutex<Set<String>>

  init(_ ids: Set<String> = []) {
    self.ids = Mutex(ids)
  }

  func load() -> Set<String> { ids.withLock { $0 } }
  func save(_ ids: Set<String>) { self.ids.withLock { $0 = ids } }
}
