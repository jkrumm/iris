import Foundation
import IrisCore
import Synchronization
import Testing

@testable import Iris

/// A credential store that lives in memory, so no unit test touches the Keychain or `UserDefaults`.
final class InMemoryCredentialStore: CredentialStore {
  private let credentials = Mutex<ConnectionCredentials?>(nil)

  init(_ credentials: ConnectionCredentials? = nil) {
    self.credentials.withLock { $0 = credentials }
  }

  func set(_ value: ConnectionCredentials?) { credentials.withLock { $0 = value } }
  func load() -> ConnectionCredentials? { credentials.withLock { $0 } }
  func save(_ value: ConnectionCredentials) throws { set(value) }
  func clear() { set(nil) }
}

/// Waits for a held call to arrive, but never forever: a gate on an endpoint the fake does not gate (or a call that
/// never happens) fails the test after `seconds` instead of hanging the whole run.
func waitUntilHeld(_ gate: FakeAPIClient.Gate, seconds: Double = 10, sourceLocation: SourceLocation = #_sourceLocation)
  async -> Bool
{
  let arrived = await withTaskGroup(of: Bool.self) { group in
    group.addTask {
      await gate.waitUntilHeld()
      return !Task.isCancelled
    }
    group.addTask {
      try? await Task.sleep(for: .seconds(seconds))
      return false
    }
    let first = await group.next() ?? false
    group.cancelAll()
    return first
  }
  if !arrived { Issue.record("no call was held within \(seconds) s", sourceLocation: sourceLocation) }
  return arrived
}
