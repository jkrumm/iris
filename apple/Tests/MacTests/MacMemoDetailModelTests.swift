import Foundation
import IrisCore
import Synchronization
import Testing

@testable import IrisMac

private final class RecordingPasteboard: Pasteboard {
  private let copies = Mutex<[String]>([])
  var last: String? { copies.withLock { $0.last } }
  func copy(_ text: String) { copies.withLock { $0.append(text) } }
}

@MainActor
@Suite("Mac memo detail model")
struct MacMemoDetailModelTests {
  private static let finished = "0b6d1f4e-3a52-4c1d-9f0e-7a2c5d8e1b34"

  private func model(
    pasteboard: RecordingPasteboard = RecordingPasteboard(), known: Bool = true
  ) async -> MacMemoDetailModel {
    let api = FakeAPIClient()
    await SampleData.seed(api)
    let memo = known ? try? await api.memo(id: Self.finished).memo : nil
    return MacMemoDetailModel(
      memoID: Self.finished, memo: memo, client: api, pasteboard: pasteboard, copiedDuration: .milliseconds(30))
  }

  @Test("a memo the list does not hold arrives with the first load, with its steps")
  func loads() async {
    let model = await model(known: false)
    #expect(model.memo == nil && model.rows(now: .now).isEmpty)
    await model.load()
    #expect(model.memo?.id == Self.finished && !model.rows(now: .now).isEmpty && !model.loadFailed)
    #expect(model.totalValue(now: .now) != nil)
  }

  @Test("a memo that cannot be loaded says so and keeps nothing")
  func loadFails() async {
    let model = MacMemoDetailModel(
      memoID: "missing", client: FakeAPIClient(), pasteboard: RecordingPasteboard())
    await model.load()
    #expect(model.memo == nil && model.loadFailed)
  }

  @Test("Copy puts the plain transcript or reply on the pasteboard and shows Copied until the timer ends")
  func copies() async {
    let pasteboard = RecordingPasteboard()
    let model = await model(pasteboard: pasteboard)
    model.copy(.transcript)
    #expect(pasteboard.last == model.memo?.plainTranscript && model.copied == .transcript)
    model.copy(.reply)
    #expect(pasteboard.last == model.memo?.plainReply && model.copied == .reply)
    #expect(await eventually { model.copied == nil })
  }

  @Test("a finished memo has nothing to retry; the waterfall starts collapsed")
  func finishedMemo() async {
    let model = await model()
    await model.load()
    #expect(model.retrySteps.isEmpty && !model.isWaterfallExpanded)
    model.isWaterfallExpanded = true
    #expect(model.isWaterfallExpanded)
  }

  @Test(
    "a memo failed at summarize offers a retry from there; the retry restarts it and the waterfall opens on its own")
  func retries() async {
    let failedID = "9e2c4b70-1a58-4d36-8f07-5b3a6d1c8e24"
    let api = FakeAPIClient()
    await SampleData.seed(api)
    let model = MacMemoDetailModel(memoID: failedID, client: api, pasteboard: RecordingPasteboard())
    await model.load()
    #expect(model.isWaterfallExpanded)
    #expect(model.retrySteps.last == .summarize)
    await model.retry(from: .summarize)
    #expect(model.failure == nil && !model.isRetrying)
    #expect(model.memo?.state != .failed)
    #expect(model.retrySteps.isEmpty)
  }
}
