import Foundation
import IrisCapture
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
  /// When the health probe behind ``connection`` last got its answer (or failed); nil before the first.
  private(set) var probedAt: Date?
  private(set) var queue: [QueuedItem] = []
  /// The persistent queue cannot be opened, so new memos are refused until it can (asking again retries).
  private(set) var queueUnavailable = false
  /// The saved queue is there but cannot be decoded, so nothing is accepted until it is reset (it is renamed aside, kept).
  private(set) var queueUnreadable = false
  /// The reset did not go through; the file is still where it was.
  private(set) var resetFailed = false
  /// The old file was set aside and kept, but a new outbox could not be opened yet.
  private(set) var resetLeftUnopened = false
  /// A Discard did not reach the queue because it could not be opened; nothing was dropped.
  private(set) var discardFailed = false
  /// Queue files earlier resets set aside, for Diagnostics to share.
  private(set) var quarantinedFiles: [URL] = []
  /// Everything the app set aside instead of deleting; shown with its size, never removed without the owner's word.
  private(set) var setAside = SetAsideSummary()
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
    queueUnreadable = available ? false : await source.isUnreadable()
    queueSaveFailure = available ? await source.saveFailure() : nil
    quarantinedFiles = await source.quarantinedFiles()
    setAside = await source.setAside()
    if available { resetLeftUnopened = false }
  }

  /// Sets the unreadable outbox file aside and opens a fresh queue. The old file and its recordings are kept.
  func resetOutbox() async {
    resetFailed = false
    resetLeftUnopened = false
    guard queueUnreadable else { return }
    switch await source.resetOutbox() {
    case .reset: break
    case .setAsideNotOpen: resetLeftUnopened = true
    case .notReset: resetFailed = true
    }
    await refreshQueue()
  }

  /// Sends a failed or stalled item again now.
  func retry(_ item: QueuedItem) async {
    await source.retry(id: item.id)
  }

  /// Drops an item from the queue, with what was recorded for it.
  func discard(_ item: QueuedItem) async {
    guard item.canDiscard else { return }
    discardFailed = !(await source.discardQueued(id: item.id))
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
    let unreadable = available ? false : await source.isUnreadable()
    let quarantined = await source.quarantinedFiles()
    let setAside = await source.setAside()
    do {
      let health = try await client.health()
      guard current == generation else { return }
      queue = items
      queueUnavailable = !available
      queueUnreadable = unreadable
      quarantinedFiles = quarantined
      self.setAside = setAside
      queueSaveFailure = saveFailure
      connection = health.status == .ok ? .connected : .degraded(health.degraded)
      probedAt = Date()
    } catch is CancellationError {
      return
    } catch {
      guard current == generation else { return }
      logger.error("health check failed: \(String(describing: error), privacy: .public)")
      queue = items
      queueUnavailable = !available
      queueUnreadable = unreadable
      quarantinedFiles = quarantined
      self.setAside = setAside
      queueSaveFailure = saveFailure
      connection = .unreachable
      probedAt = Date()
    }
  }
}
