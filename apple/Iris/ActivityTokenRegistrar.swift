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
    /// A `PUT` is out: the next one waits for its answer, so answers arrive in the order the tokens were sent.
    var isSending = false
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
  ///
  /// One request per memo at a time: a token that rotates while a `PUT` is out is sent after its answer, never beside it, so
  /// a slow answer for an older token cannot land after (and replace) a newer one, here or on the server. The call that
  /// finds a `PUT` out returns at once; the call that sent it carries on with the newest token.
  func attempt(_ memoID: String) async {
    guard entries[memoID]?.isSending == false else { return }
    entries[memoID]?.isSending = true
    defer { entries[memoID]?.isSending = false }
    while let entry = entries[memoID], entry.memoExists, let token = entry.token, token != entry.registeredToken {
      do {
        try await client.setActivityToken(memoID: memoID, request: ActivityTokenRequest(token: token))
      } catch {
        logger.error("activity token not registered: \(String(describing: error), privacy: .public)")
        retryLater(memoID)
        return
      }
      guard entries[memoID] != nil else { return }  // the activity ended while the request was out
      entries[memoID]?.registeredToken = token
      entries[memoID]?.retry?.cancel()
      entries[memoID]?.retry = nil
      entries[memoID]?.retryDelay = .seconds(2)
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
