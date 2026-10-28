import IrisCore
import Observation
import os

/// The Settings tab: whether the server answers, and the queue of items waiting to be sent.
@Observable
final class SettingsModel {
  enum Connection: Equatable {
    /// No server URL or device token saved yet; the connection form is the next step.
    case notConfigured
    case checking
    case connected
    case degraded([String])
    case unreachable
  }

  private(set) var connection = Connection.checking
  private(set) var queue: [QueuedItem] = []

  private let client: any APIClient
  private let source: any QueuedItemSource
  private let credentials: (any CredentialStore)?
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "settings")

  /// Bumped by every load; an answer that finds it changed belongs to a load that has been superseded.
  private var generation = 0

  /// - Parameter credentials: The store the connection comes from; nil for the fake composition, which always has one.
  init(
    client: any APIClient, queue source: any QueuedItemSource = EmptyQueue(),
    credentials: (any CredentialStore)? = nil
  ) {
    self.client = client
    self.source = source
    self.credentials = credentials
    if let credentials, credentials.load() == nil { connection = .notConfigured }
  }

  func load() async {
    generation += 1
    let current = generation
    if let credentials, credentials.load() == nil {
      connection = .notConfigured
      return
    }
    let items = await source.queuedItems()
    do {
      let health = try await client.health()
      guard current == generation else { return }
      queue = items
      connection = health.status == .ok ? .connected : .degraded(health.degraded)
    } catch is CancellationError {
      return
    } catch {
      guard current == generation else { return }
      logger.error("health check failed: \(String(describing: error), privacy: .public)")
      queue = items
      connection = .unreachable
    }
  }
}
