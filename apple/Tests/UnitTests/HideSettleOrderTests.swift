import Foundation
import IrisCore
import Testing

@testable import Iris

/// Wave 19 I1: a discarded take's server `DELETE` can be acknowledged before the cancel has told History to hide the memo
/// (`TakeController.cancel` hides after the session queued the delete). Either order must end with the memo gone and
/// nothing left hidden for good.
@MainActor
@Suite("Hide and settle")
struct HideSettleOrderTests {
  private let fake = FakeAPIClient(now: { MemoFactory.now })

  @Test("a delete that settled before the hide arrived leaves nothing hidden, and the row is gone")
  func settleBeforeHide() {
    let store = InMemoryHiddenMemoStore()
    let history = HistoryModel(client: fake, hiddenStore: store)
    history.insert(MemoFactory.memo("cancelled"))
    #expect(history.memos.map(\.id) == ["cancelled"])

    history.unhide("cancelled")  // the server's DELETE was acknowledged first
    history.hide("cancelled")

    #expect(history.memos.isEmpty)
    #expect(store.load().isEmpty, "the id would never be unhidden again: it is not kept")
  }

  @Test("the hide before the settle behaves as before")
  func hideThenSettle() {
    let store = InMemoryHiddenMemoStore()
    let history = HistoryModel(client: fake, hiddenStore: store)
    history.insert(MemoFactory.memo("cancelled"))

    history.hide("cancelled")
    #expect(store.load() == ["cancelled"])
    history.unhide("cancelled")
    #expect(store.load().isEmpty)
  }
}
