import Foundation
import IrisCore
import os

/// Keeps each take's Live Activity push token on the server (`PUT /memos/:id/activity-token`), which answers 404 until it
/// has the memo. ActivityKit only delivers the token; this decides when it is sent.
final class ActivityTokenRegistrar {
  private struct Entry {
    var token: String?
    var memoExists = false
    var registeredToken: String?
    var handedOver = false
    var retry: Task<Void, Never>?
    var retryDelay = Duration.seconds(2)
  }

  private let client: any APIClient
  private let sleep: (Duration) async throws -> Void
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "liveactivity")
  private var entries: [String: Entry] = [:]

  init(client: any APIClient, sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
    self.client = client
    self.sleep = sleep
  }

  func begin(_ memoID: String) {
    entries[memoID] = Entry()
  }

  func isTracking(_ memoID: String) -> Bool { entries[memoID] != nil }

  func setToken(_ memoID: String, _ token: String) async {
    entries[memoID]?.token = token
    await attempt(memoID)
  }

  func memoCreated(_ memoID: String) async {
    entries[memoID]?.memoExists = true
    await attempt(memoID)
  }

  /// The memo is on the server and its pushes carry the activity from here: the activity stays tracked, because the
  /// server still needs its current token, now and after every rotation, until `finish`.
  func handOver(_ memoID: String) async {
    entries[memoID]?.handedOver = true
    await attempt(memoID)
  }

  /// The activity is over (its token stream ended): nothing more is sent for it.
  func finish(_ memoID: String) {
    entries[memoID]?.retry?.cancel()
    entries[memoID] = nil
  }

  /// Sends the current token when the server has the memo and has not confirmed that token yet. A failure is logged; a
  /// handed-over activity has no later update to try again with, so it retries on its own with a growing delay.
  func attempt(_ memoID: String) async {
    guard let entry = entries[memoID], entry.memoExists, let token = entry.token, token != entry.registeredToken else {
      return
    }
    do {
      try await client.setActivityToken(memoID: memoID, request: ActivityTokenRequest(token: token))
      entries[memoID]?.registeredToken = token
      entries[memoID]?.retry?.cancel()
      entries[memoID]?.retry = nil
      entries[memoID]?.retryDelay = .seconds(2)
    } catch {
      logger.error("activity token not registered: \(String(describing: error), privacy: .public)")
      retryLater(memoID)
    }
  }

  private func retryLater(_ memoID: String) {
    guard let entry = entries[memoID], entry.handedOver, entry.retry == nil else { return }
    let delay = entry.retryDelay
    entries[memoID]?.retryDelay = min(delay * 2, .seconds(300))
    // Owned by the entry; cancelled when the token is confirmed and by `finish`. A failed attempt schedules the next one.
    entries[memoID]?.retry = Task { [sleep] in
      try? await sleep(delay)
      guard !Task.isCancelled else { return }
      entries[memoID]?.retry = nil
      await attempt(memoID)
    }
  }
}
