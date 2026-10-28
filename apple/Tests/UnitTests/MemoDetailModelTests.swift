import Foundation
import IrisCore
import Testing

@testable import Iris

@MainActor
@Suite("MemoDetailModel")
struct MemoDetailModelTests {
  let client = FakeAPIClient(now: { MemoFactory.now })

  private func model(_ memo: Memo, steps: [StepEntry] = []) async -> MemoDetailModel {
    await client.seed(MemoFactory.detail(memo, steps: steps))
    return MemoDetailModel(memo: memo, client: client, media: FakeMediaSource())
  }

  private func failed(typed: Bool = false, at step: MemoStep = .summarize) -> Memo {
    MemoFactory.memo("f", state: .failed, route: "hermes", failedStep: step, error: "boom", typed: typed)
  }

  @Test("load brings the steps and the stats baselines, and asks for the stats once")
  func loadsStepsAndBaselinesOnce() async {
    await client.setStats(
      Stats(
        days: 30, from: "a", to: "b",
        stepMedians: [StatsStepMedian(step: .act, route: "hermes", medianMs: 5_000, samples: 30)]))
    let memo = MemoFactory.memo("m", route: "hermes")
    let detail = await model(memo, steps: [MemoFactory.step(.act, at: 0, for: 10)])
    #expect(detail.detail.steps.isEmpty)

    await detail.load()
    await detail.load()
    #expect(detail.detail.steps.count == 1)
    #expect(detail.rows(now: MemoFactory.now)[0].badge?.tone == .slower)
    let statsCalls = await client.calls.filter { if case .stats = $0 { true } else { false } }
    #expect(statsCalls.count == 1)
  }

  @Test("a failed load keeps what the screen already has")
  func failedLoadKeepsDetail() async {
    let memo = MemoFactory.memo("m", transcript: "hello")
    let detail = await model(memo)
    await client.enqueueFailure(.unexpectedStatus(500), for: .memo)
    await detail.load()
    #expect(detail.memo.transcript == "hello")
  }

  @Test("retry calls the server with that step and shows the memo it returns")
  func retryFromStep() async {
    let detail = await model(failed(), steps: [MemoFactory.step(.summarize, at: 0, for: 1, status: .failed)])
    await detail.retry(from: .act)
    #expect(await client.calls.contains(.retryMemo(id: "f", request: RetryMemoRequest(from: .act))))
    #expect(detail.memo.state == .received)
    #expect(detail.failure == nil)
  }

  @Test("a plain tap retries from the step that failed; the choices run up to it")
  func retryChoices() async {
    let detail = await model(failed())
    #expect(detail.retrySteps == [.transcribe, .route, .act, .summarize])
    #expect(detail.primaryRetryStep == .summarize)
  }

  @Test("a typed memo has no recording, so it cannot retry from transcribe")
  func typedRetry() async {
    let detail = await model(failed(typed: true))
    #expect(detail.retrySteps == [.route, .act, .summarize])
  }

  @Test("only a failed memo can retry, and only from a step up to the failure")
  func retryGuards() async {
    let done = await model(MemoFactory.memo("d", state: .notified))
    #expect(done.retrySteps.isEmpty)
    await done.retry(from: .act)
    #expect(await client.calls.allSatisfy { if case .retryMemo = $0 { false } else { true } })

    let early = await model(failed(at: .route))
    await early.retry(from: .notify)
    #expect(await client.calls.allSatisfy { if case .retryMemo = $0 { false } else { true } })
  }

  @Test("a refused retry says so and leaves the memo failed")
  func retryFailure() async {
    let detail = await model(failed())
    await client.enqueueFailure(.unexpectedStatus(500), for: .retryMemo)
    await detail.retry(from: .summarize)
    #expect(detail.failure != nil)
    #expect(detail.memo.state == .failed)
    detail.dismissFailure()
    #expect(detail.failure == nil)
  }

  @Test("play and reply need a finished memo with something to say")
  func replyActions() async {
    let spoken = MemoSummary(headline: "h", detail: "d", spoken: "s")
    let ready = await model(MemoFactory.memo("a", state: .notified, summary: spoken, replyText: "Alles notiert."))
    #expect(ready.canPlayReply)
    #expect(ready.canReply)
    let running = await model(MemoFactory.memo("b", state: .acted, replyText: "x"))
    #expect(!running.canPlayReply)
    let silent = await model(MemoFactory.memo("c", state: .notified))
    #expect(!silent.canPlayReply)
    #expect(silent.canReply)
  }
}
