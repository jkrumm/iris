import IrisCore
import Observation
import os

/// Loads the memo list through an `APIClient`. Shared by the iOS history screen and the Mac menu bar panel.
@Observable
final class HistoryModel {
  private(set) var memos: [Memo] = []
  private(set) var loadFailed = false

  private let client: any APIClient
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "history")

  init(client: any APIClient) {
    self.client = client
  }

  func load() async {
    do {
      memos = try await client.listMemos(ListMemosQuery(limit: 50)).items
      loadFailed = false
    } catch is CancellationError {
      return
    } catch {
      logger.error("history load failed: \(String(describing: error), privacy: .public)")
      loadFailed = true
    }
  }
}
