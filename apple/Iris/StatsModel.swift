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

  init(client: any APIClient) {
    self.client = client
  }

  /// The report for the current granularity; nil until the first load succeeds.
  var report: StatsReport? {
    stats.map { StatsReport(stats: $0, granularity: granularity) }
  }

  /// Loads the window. A failure keeps what is on screen; the error state only shows when there is nothing yet.
  func load() async {
    isLoading = true
    defer { isLoading = false }
    do {
      stats = try await client.stats(StatsQuery(days: StatsReport.windowDays))
      loadFailed = false
    } catch is CancellationError {
      return
    } catch {
      logger.error("stats load failed: \(String(describing: error), privacy: .public)")
      loadFailed = true
    }
  }
}
