import Foundation
import IrisCore
import Testing

@testable import Iris

@MainActor
@Suite("DecisionsModel")
struct DecisionsModelTests {
  let client = FakeAPIClient()
  let model: DecisionsModel
  private let counter = CallCounter()

  init() {
    let counter = counter
    model = DecisionsModel(client: client, makeCallID: { counter.next() })
  }

  private func seed() async {
    await client.setFactoryBoard(SampleData.factoryBoard(now: Date(timeIntervalSince1970: 1_800_000_000)))
  }

  private func answerCalls() async -> [FactoryAnswerRequest] {
    await client.calls.compactMap { call in
      if case .answerFactoryAsk(let request) = call { request } else { nil }
    }
  }

  @Test("a load shows the asks and the health line; the badge counts answerable asks that are not stale")
  func loads() async {
    #expect(model.board == nil && model.openCount == 0)
    await seed()
    await model.load()
    #expect(model.asks.count == 3)
    #expect(model.health.count == 1)
    #expect(model.board?.counts == FactoryCounts(asks: 3, health: 1))
    #expect(model.openCount == 2)
    #expect(model.loadProblem == nil)
  }

  @Test("a 503 keeps the board on screen and says the factory is unreachable; another failure is a plain failure")
  func loadFailures() async {
    await seed()
    await model.load()
    let server503 = APIError.server(status: 503, body: ErrorBody(error: .unavailable, message: "down"))
    await client.enqueueFailure(server503, for: .factory)
    await model.load()
    #expect(model.loadProblem == .unreachable)
    #expect(model.asks.count == 3)

    await client.enqueueFailure(.unexpectedStatus(500), for: .factory)
    await model.load()
    #expect(model.loadProblem == .failed)

    await model.load()
    #expect(model.loadProblem == nil)
  }

  // The card removal once read `board` while writing into it: an exclusivity trap that only the optimizer's evaluation order
  // exposes (TestFlight 702 crashed; the Debug unit run stays green). Reproduce it with
  // `xcodebuild test -configuration Release ENABLE_TESTABILITY=YES -only-testing:IrisTests/DecisionsModelTests`.
  @Test("an answer is sent once, removes the card and refreshes")
  func answerSucceeds() async {
    await seed()
    await model.load()
    await model.answer(askID: "sample:cache", text: "Keep Redis")
    #expect(await answerCalls() == [FactoryAnswerRequest(askId: "sample:cache", text: "Keep Redis", callId: "call-1")])
    #expect(model.asks.map(\.id) == ["sample:release", "sample:review"])
    #expect(model.openCount == 1)
    #expect(model.answers["sample:cache"] == nil)
    #expect(await client.calls.filter { $0 == .factory }.count == 2)
  }

  @Test("offline fails the card; sending again reuses the call id and succeeds")
  func retryReusesCallID() async {
    await seed()
    await model.load()
    await client.enqueueFailure(.transport(.notConnectedToInternet), for: .answerFactoryAsk)
    await model.answer(askID: "sample:cache", text: "Keep Redis")
    #expect(model.answers["sample:cache"] == .failed(.unreachable))
    #expect(model.asks.count == 3)

    await model.answer(askID: "sample:cache", text: "Keep Redis")
    let calls = await answerCalls()
    #expect(calls.map(\.callId) == ["call-1", "call-1"])
    #expect(model.answers["sample:cache"] == nil)
    #expect(model.asks.count == 2)
  }

  @Test("another text for the same card is a new call")
  func newTextNewCallID() async {
    await seed()
    await model.load()
    await client.enqueueFailure(.unexpectedStatus(500), for: .answerFactoryAsk)
    await model.answer(askID: "sample:cache", text: "Keep Redis")
    #expect(model.answers["sample:cache"] == .failed(.other))
    await model.answer(askID: "sample:cache", text: "Move in-process")
    #expect(await answerCalls().map(\.callId) == ["call-1", "call-2"])
  }

  @Test("a 404 says the ask was already answered and refreshes")
  func alreadyAnswered() async {
    await seed()
    await model.load()
    await client.enqueueFailure(
      .server(status: 404, body: ErrorBody(error: .notFound, message: "gone")), for: .answerFactoryAsk)
    await model.answer(askID: "sample:cache", text: "Keep Redis")
    #expect(model.notice == .alreadyAnswered)
    #expect(model.answers["sample:cache"] == nil)
    #expect(await client.calls.filter { $0 == .factory }.count == 2)
    model.dismissNotice()
    #expect(model.notice == nil)
  }

  @Test("a 409 marks the card as no longer open")
  func closed() async {
    await seed()
    await model.load()
    await client.enqueueFailure(
      .server(status: 409, body: ErrorBody(error: .badState, message: "no open question")), for: .answerFactoryAsk)
    await model.answer(askID: "sample:cache", text: "Keep Redis")
    #expect(model.answers["sample:cache"] == .failed(.closed))
  }

  @Test("an answer is not sent twice while it is in flight, and blank text is not sent")
  func inFlight() async {
    await seed()
    await model.load()
    let gate = await client.hold(.answerFactoryAsk)
    let first = Task { await model.answer(askID: "sample:cache", text: "Keep Redis") }
    await gate.waitUntilHeld()
    #expect(model.answers["sample:cache"] == .sending)
    await model.answer(askID: "sample:cache", text: "Keep Redis")
    await model.answer(askID: "sample:release", text: "   ")
    gate.release()
    await first.value
    #expect(await answerCalls().count == 1)
  }

  @Test("a push tap marks the card and loads fresh data")
  func pushTap() async {
    await seed()
    await model.focus(askID: "sample:release")
    #expect(model.highlightedAskID == "sample:release")
    #expect(model.asks.contains { $0.id == "sample:release" })
    model.clearHighlight()
    #expect(model.highlightedAskID == nil)
  }

  @Test("the ask id comes out of the notification's factory payload, and nothing else")
  func pushPayload() {
    let info: [AnyHashable: Any] = ["aps": ["alert": "x"], "factory": ["askId": "decision:1", "issue": 1]]
    #expect(FactoryPush.askID(userInfo: info) == "decision:1")
    #expect(FactoryPush.askID(userInfo: ["memo": "m1"]) == nil)
    #expect(FactoryPush.askID(userInfo: ["factory": ["askId": ""]]) == nil)
  }

  @Test("the router holds a tap until the root consumes it")
  func router() {
    let router = FactoryTapRouter()
    #expect(router.pendingAskID == nil)
    router.tapped(askID: "a")
    #expect(router.pendingAskID == "a")
    router.consume()
    #expect(router.pendingAskID == nil)
  }
}

/// Call ids `call-1`, `call-2`, … in the order the model asks for them.
private final class CallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func next() -> String {
    lock.withLock {
      value += 1
      return "call-\(value)"
    }
  }
}
