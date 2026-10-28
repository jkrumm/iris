import IrisCore
import Observation
import os

/// The Settings tab: whether the server answers, and the queue of items waiting to be sent.
@Observable
final class SettingsModel {
  enum Connection: Equatable {
    case checking
    case connected
    case degraded([String])
    case unreachable
  }

  private(set) var connection = Connection.checking
  private(set) var queue: [QueuedItem] = []

  private let client: any APIClient
  private let source: any QueuedItemSource
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "settings")

  init(client: any APIClient, queue source: any QueuedItemSource = EmptyQueue()) {
    self.client = client
    self.source = source
  }

  func load() async {
    queue = await source.queuedItems()
    do {
      let health = try await client.health()
      connection = health.status == .ok ? .connected : .degraded(health.degraded)
    } catch is CancellationError {
      return
    } catch {
      logger.error("health check failed: \(String(describing: error), privacy: .public)")
      connection = .unreachable
    }
  }
}
