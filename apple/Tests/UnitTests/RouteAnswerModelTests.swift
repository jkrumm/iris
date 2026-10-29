import Foundation
import IrisCore
import Testing

@testable import Iris

@MainActor
@Suite("RouteAnswerModel")
struct RouteAnswerModelTests {
  let client = FakeAPIClient(now: { MemoFactory.now })

  private func parked(suggestion: String? = nil, reason: String? = "Not sure") -> Memo {
    MemoFactory.memo("p", state: .needsRoute, routeReason: reason, routeSuggestion: suggestion)
  }

  private func model(_ memo: Memo, onStale: @escaping () -> Void = {}) async -> RouteAnswerModel {
    await client.seed(MemoFactory.detail(memo))
    return RouteAnswerModel(memo: memo, client: client, onStale: onStale)
  }

  private func stub(_ status: Int, _ code: APIErrorCode, _ message: String) -> APIError {
    .server(status: status, body: ErrorBody(error: code, message: message))
  }

  // MARK: Preselection

  @Test("a park preselects the model's suggestion, else Hermes")
  func preselectsTheSuggestion() async {
    #expect(await model(parked(suggestion: "journal")).destination == .journal)
    #expect(await model(parked(suggestion: "tab")).destination == .herdr)
    #expect(await model(parked(suggestion: nil)).destination == .hermes)
    #expect(await model(parked(suggestion: "nonsense")).destination == .hermes)
  }

  @Test("a correction starts from the route the memo took and shows no park reason")
  func correctionStartsFromTheRoute() async {
    let acted = MemoFactory.memo("a", state: .acted, route: "journal")
    let model = await model(acted)
    #expect(model.kind == .correction)
    #expect(model.destination == .journal)
    #expect(model.reason == nil)
    #expect(model.suggestion == nil)
  }

  @Test("the reason and the suggestion of a park are shown")
  func showsReasonAndSuggestion() async {
    let model = await model(parked(suggestion: "journal", reason: "Journal or Hermes?"))
    #expect(model.kind == .answer)
    #expect(model.reason == "Journal or Hermes?")
    #expect(model.suggestion == .journal)
  }

  @Test("only a parked memo, or a finished one with a route, can be routed")
  func canRoute() {
    #expect(RouteAnswerModel.canRoute(MemoFactory.memo("a", state: .needsRoute)))
    #expect(RouteAnswerModel.canRoute(MemoFactory.memo("a", state: .notified, route: "hermes")))
    #expect(RouteAnswerModel.canRoute(MemoFactory.memo("a", state: .acted, route: "hermes")))
    #expect(!RouteAnswerModel.canRoute(MemoFactory.memo("a", state: .notified)))
    #expect(!RouteAnswerModel.canRoute(MemoFactory.memo("a", state: .routed, route: "hermes")))
    #expect(!RouteAnswerModel.canRoute(MemoFactory.memo("a", state: .failed, route: "hermes")))
  }

  // MARK: Answering

  @Test("sending routes the parked memo and keeps the answer")
  func answers() async {
    let model = await model(parked(suggestion: "journal"))
    let memo = await model.submit()
    #expect(memo?.state == .routed)
    #expect(model.routed?.route == "journal")
    #expect(await client.calls.contains(.routeMemo(id: "p", request: RouteRequest(destination: .journal))))
    #expect(!model.canSubmit, "a second answer would be a 409")
  }

  @Test("a correction after act is logged and leaves the memo as it was")
  func corrects() async {
    let notified = MemoFactory.memo("n", state: .notified, route: "hermes", replyText: "ok")
    let model = await model(notified)
    model.destination = .journal
    let memo = await model.submit()
    #expect(memo?.state == .notified)
    #expect(memo?.route == "hermes")
    #expect(await client.calls.contains(.routeMemo(id: "n", request: RouteRequest(destination: .journal))))
  }

  // MARK: herdr

  @Test("herdr needs a tab: the herd is read, and Send waits for a pick")
  func herdrNeedsATab() async {
    let herd = Herd(tabs: [
      HerdTab(id: "t1", repo: "iris", label: "iris", agentState: .working),
      HerdTab(id: "t2", repo: "dotfiles", label: "dotfiles", agentState: .idle),
    ])
    await client.setHerd(herd)
    let model = await model(parked())
    model.destination = .herdr
    #expect(model.tabs == .loading)
    #expect(!model.canSubmit)

    await model.loadHerd()
    guard case .loaded(let tabs) = model.tabs else {
      Issue.record("tabs not loaded: \(model.tabs)")
      return
    }
    #expect(tabs.map(\.id) == ["t1", "t2"])
    #expect(tabs.first?.subtitle == "iris · working")
    #expect(!model.canSubmit)

    model.tab = "t2"
    #expect(model.canSubmit)
    _ = await model.submit()
    #expect(await client.calls.contains(.routeMemo(id: "p", request: RouteRequest(destination: .herdr, tab: "t2"))))
  }

  @Test("a herd with one tab preselects it")
  func singleTab() async {
    await client.setHerd(Herd(tabs: [HerdTab(id: "only", repo: "iris", label: "iris", agentState: .idle)]))
    let model = await model(parked())
    model.destination = .herdr
    await model.loadHerd()
    #expect(model.tab == "only")
    #expect(model.canSubmit)
  }

  @Test("a herd that cannot be read, or is empty, blocks herdr and says so")
  func herdUnavailable() async {
    await client.enqueueFailure(stub(503, .unavailable, "herdr down"), for: .herd)
    let model = await model(parked())
    model.destination = .herdr
    await model.loadHerd()
    guard case .unavailable = model.tabs else {
      Issue.record("expected unavailable, got \(model.tabs)")
      return
    }
    #expect(!model.canSubmit)

    // The next look retries, and an empty herd is unavailable too.
    await model.loadHerd()
    guard case .unavailable = model.tabs else {
      Issue.record("an empty herd has no tab: \(model.tabs)")
      return
    }
  }

  @Test("choosing herdr again after leaving it starts the herd load over")
  func herdLoadAfterSwitchingAway() async {
    await client.setHerd(Herd(tabs: [HerdTab(id: "a", repo: "iris", label: "iris", agentState: .idle)]))
    let model = await model(parked())
    model.destination = .herdr
    await model.loadHerd()
    model.destination = .journal
    model.destination = .herdr
    await model.loadHerd()
    guard case .loaded = model.tabs else {
      Issue.record("tabs not loaded: \(model.tabs)")
      return
    }
  }

  @Test("the tab goes on the wire only for herdr")
  func tabOnlyForHerdr() async {
    let model = await model(parked())
    model.tab = "stale"
    model.destination = .journal
    _ = await model.submit()
    #expect(await client.calls.contains(.routeMemo(id: "p", request: RouteRequest(destination: .journal, tab: nil))))
  }

  // MARK: Refusals

  @Test("400 not available keeps the sheet open with a message naming the destination")
  func notAvailable() async {
    await client.enqueueFailure(stub(400, .badRequest, "journal not available"), for: .routeMemo)
    let model = await model(parked())
    model.destination = .journal
    #expect(await model.submit() == nil)
    #expect(model.failure?.contains(RouteDestination.journal.title) == true)
    #expect(model.routed == nil)
    #expect(model.canSubmit, "another destination can be tried")
  }

  @Test("409 says the memo was already routed and asks for a refresh")
  func alreadyRouted() async {
    await client.enqueueFailure(stub(409, .badState, "bad state"), for: .routeMemo)
    var refreshed = false
    let model = await model(parked()) { refreshed = true }
    #expect(await model.submit() == nil)
    #expect(refreshed)
    #expect(model.failure != nil)
  }

  @Test("a network failure is a message and nothing else")
  func transport() async {
    await client.enqueueFailure(.transport(.notConnectedToInternet), for: .routeMemo)
    let model = await model(parked())
    #expect(await model.submit() == nil)
    #expect(model.failure != nil)
    #expect(model.canSubmit)
  }
}
