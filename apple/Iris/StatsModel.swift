import IrisCore
import Observation
import os

/// The Stats tab's data: one `GET /v1/stats` for the whole window, read as days or weeks without asking again.
@Observable
final class StatsModel {
  private(set) var stats: Stats?
  private(set) var loadFailed = false
  private(set) var isLoading = false
  var granularity: StatsReport.Granularity = .days

  private let client: any APIClient
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "stats")
  /// Bumped by every load; an answer that finds it changed belongs to a load that has been superseded.
  private var generation = 0

  init(client: any APIClient) {
    self.client = client
  }

  /// The report for the current granularity; nil until the first load succeeds.
  var report: StatsReport? {
    stats.map { StatsReport(stats: $0, granularity: granularity) }
  }

  /// Loads the window. A failure keeps what is on screen; the error state only shows when there is nothing yet.
  func load() async {
    generation += 1
    let current = generation
    isLoading = true
    defer { if current == generation { isLoading = false } }
    do {
      let loaded = try await client.stats(StatsQuery(days: StatsReport.windowDays))
      guard current == generation else { return }
      stats = loaded
      loadFailed = false
    } catch is CancellationError {
      return
    } catch {
      guard current == generation else { return }
      logger.error("stats load failed: \(String(describing: error), privacy: .public)")
      loadFailed = true
    }
  }
}
