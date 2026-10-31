import IrisCore
import IrisUI
import WidgetKit

extension Memo {
  /// What the widgets may know of this memo (`LastMemoSnapshot`): the state, the route chip once it is routed, and the
  /// server's summary headline. Never the transcript (a memo without a summary has no headline: the widget says what
  /// state it is in), the reply, the park reason or an error.
  var widgetObservation: WidgetMemoObservation {
    let phase: LastMemoSnapshot.Phase =
      switch state {
      case .failed: .failed
      case .notified: .done
      case .needsRoute: done ? .done : .needsRoute
      case .receiving, .received, .transcribed, .routed, .acted, .summarized: .processing
      }
    return WidgetMemoObservation(
      id: id, createdAt: createdAt, phase: phase, routeChip: route == nil ? nil : routeLabel,
      headline: summary?.headline, isDeleted: isDeleted)
  }
}

extension LastMemoWidgetFeed {
  /// The app's feed: the App Group file in production (unavailable without the entitlement, then nothing is written), memory
  /// on fakes, so a UI test or a simulator run never touches a real container or reloads a placed widget.
  static func app(fake: Bool) -> LastMemoWidgetFeed {
    LastMemoWidgetFeed(
      store: fake ? InMemoryLastMemoSnapshotStore() : FileLastMemoSnapshotStore.appGroup(),
      reload: { if !fake { WidgetCenter.shared.reloadTimelines(ofKind: IrisWidgetKind.lastMemo) } })
  }

  /// History is the feed's only source: what it learns from its server goes in, what the user discards goes out.
  func attach(to history: HistoryModel) {
    history.onMemoObserved = { [self] memo in observe(memo.widgetObservation) }
    history.onMemoForgotten = { [self] id in forget(id: id) }
  }
}
