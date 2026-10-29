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
  /// The persistent queue cannot be opened, so new memos are refused until it can (asking again retries).
  private(set) var queueUnavailable = false
  /// Why the queue could not be saved to disk; it is retried on its own. `nil` while it can be.
  private(set) var queueSaveFailure: String?

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

  /// Follows the queue for as long as the screen is up: every change of the outbox refreshes the list.
  func observeQueue() async {
    await refreshQueue()
    for await _ in await source.changes() {
      guard !Task.isCancelled else { return }
      await refreshQueue()
    }
  }

  private func refreshQueue() async {
    let available = await source.isAvailable()
    queue = available ? await source.queuedItems() : []
    queueUnavailable = !available
    queueSaveFailure = available ? await source.saveFailure() : nil
  }

  /// Sends a failed or stalled item again now.
  func retry(_ item: QueuedItem) async {
    await source.retry(id: item.id)
  }

  /// Drops an item from the queue, with what was recorded for it.
  func discard(_ item: QueuedItem) async {
    guard item.canDiscard else { return }
    await source.discard(id: item.id)
  }

  func load() async {
    generation += 1
    let current = generation
    if let credentials, credentials.load() == nil {
      connection = .notConfigured
      return
    }
    // Asked once per refresh: a closed queue is opened again by this question, not by every read after it.
    let available = await source.isAvailable()
    let items = available ? await source.queuedItems() : []
    let saveFailure = available ? await source.saveFailure() : nil
    do {
      let health = try await client.health()
      guard current == generation else { return }
      queue = items
      queueUnavailable = !available
      queueSaveFailure = saveFailure
      connection = health.status == .ok ? .connected : .degraded(health.degraded)
    } catch is CancellationError {
      return
    } catch {
      guard current == generation else { return }
      logger.error("health check failed: \(String(describing: error), privacy: .public)")
      queue = items
      queueUnavailable = !available
      queueSaveFailure = saveFailure
      connection = .unreachable
    }
  }
}
