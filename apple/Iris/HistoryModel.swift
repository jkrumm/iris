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
      let page = try await client.listMemos(ListMemosQuery(limit: 50))
      // A memo answered after the first page can repeat across pinned and items: pinned first, then the new ids.
      let pinnedIDs = Set(page.pinned.map(\.id))
      memos = page.pinned + page.items.filter { !pinnedIDs.contains($0.id) }
      loadFailed = false
    } catch is CancellationError {
      return
    } catch {
      logger.error("history load failed: \(String(describing: error), privacy: .public)")
      loadFailed = true
    }
  }
}
