import Foundation
import IrisCapture
import IrisCore
import Testing

@testable import Iris

/// The live preview's model on the scripted recognizer: partial and final text, an unsupported language, a failing recognizer,
/// and the take that goes on whatever the preview does.
@MainActor
@Suite("Live preview")
struct LivePreviewTests {
  private func waitFor(seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
    for _ in 0..<Int(seconds * 100) {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
  }

  private func recorder() -> FakeSegmentRecorder {
    FakeSegmentRecorder(
      directory: FileManager.default.temporaryDirectory.appending(path: "iris-preview-\(UUID().uuidString)"))
  }

  private func engine(_ script: [FakeLivePreviewEngine.Step], available: Bool = true) -> FakeLivePreviewEngine {
    FakeLivePreviewEngine(available: available, script: script, chunksPerStep: 1)
  }

  /// A preview of one take on `recorder`; feeds one tap-sized buffer per call.
  private func start(_ script: [FakeLivePreviewEngine.Step], available: Bool = true) async throws -> (
    LivePreviewModel, FakeSegmentRecorder
  ) {
    let recorder = recorder()
    let model = LivePreviewModel(source: .fake(tap: recorder, engine: engine(script, available: available)))
    model.begin(memo: MemoID())
    try await recorder.start(memoID: MemoID())
    return (model, recorder)
  }

  @Test("partial text replaces itself and a final result is kept, in primary ink")
  func partialThenFinal() async throws {
    let (model, recorder) = try await start([
      .volatile("Remind me"), .volatile("Remind me to call"), .final("Remind me to call."), .volatile("and"),
    ])
    #expect(await waitFor { model.isRunning })

    await recorder.feed(frames: 4096)
    #expect(await waitFor { model.volatile == "Remind me" })
    await recorder.feed(frames: 4096)
    #expect(await waitFor { model.volatile == "Remind me to call" })
    #expect(model.finalized.isEmpty)

    await recorder.feed(frames: 4096)
    #expect(await waitFor { model.finalized == "Remind me to call." })
    #expect(model.volatile.isEmpty, "a final result settles the volatile text")

    await recorder.feed(frames: 4096)
    #expect(await waitFor { model.volatile == "and" })
    #expect(model.finalized == "Remind me to call.")
  }

  @Test("an unsupported or not installed language shows no preview, and the take's audio still flows")
  func unavailableLanguage() async throws {
    let (model, recorder) = try await start([.volatile("never")], available: false)
    await recorder.feed(frames: 4096)
    try await Task.sleep(for: .milliseconds(200))
    #expect(!model.isRunning)
    #expect(model.volatile.isEmpty && model.finalized.isEmpty)
    try await recorder.stop()  // the take ends as it always does
  }

  @Test("a recognizer that fails clears the preview, does not come back for the same take, and does not touch the take")
  func recognizerFails() async throws {
    let recorder = recorder()
    let memo = MemoID()
    let model = LivePreviewModel(
      source: .fake(tap: recorder, engine: engine([.volatile("one"), .fail, .volatile("two")])))
    model.begin(memo: memo)
    try await recorder.start(memoID: memo)
    #expect(await waitFor { model.isRunning })

    await recorder.feed(frames: 4096)
    #expect(await waitFor { model.volatile == "one" })
    await recorder.feed(frames: 4096)
    #expect(await waitFor { !model.isRunning })
    #expect(model.volatile.isEmpty && model.finalized.isEmpty)

    model.begin(memo: memo)  // a pause and resume of the same take
    try await Task.sleep(for: .milliseconds(100))
    #expect(!model.isRunning, "the failed preview stays off for this take")

    await recorder.feed(frames: 4096)  // the recorder is untouched
    try await recorder.stop()
  }

  @Test("ending the take clears the text and ends the stream")
  func endClears() async throws {
    let (model, recorder) = try await start([.final("Hello.")])
    #expect(await waitFor { model.isRunning })
    await recorder.feed(frames: 4096)
    #expect(await waitFor { model.finalized == "Hello." })

    model.end()
    #expect(model.finalized.isEmpty && model.volatile.isEmpty && !model.isRunning)
  }

  @Test("a pause stops feeding: the text stands still until audio comes back")
  func pauseHoldsTheText() async throws {
    let (model, recorder) = try await start([.volatile("a"), .volatile("a b")])
    #expect(await waitFor { model.isRunning })
    await recorder.feed(frames: 4096)
    #expect(await waitFor { model.volatile == "a" })

    await recorder.pause()
    await recorder.feed(frames: 4096)
    try await Task.sleep(for: .milliseconds(150))
    #expect(model.volatile == "a")

    await recorder.resume()
    await recorder.feed(frames: 4096)
    #expect(await waitFor { model.volatile == "a b" })
  }

  @Test("without a source there is no preview")
  func noSource() async throws {
    let model = LivePreviewModel(source: nil)
    model.begin(memo: MemoID())
    #expect(!model.isRunning)
  }

  @Test("settled text keeps its last 600 characters, cut at a word")
  func tailIsBounded() {
    let words = (0..<400).map { "w\($0)" }.joined(separator: " ")
    let kept = LivePreviewModel.tail(words)
    #expect(kept.count <= LivePreviewModel.maxCharacters)
    #expect(kept.hasSuffix("w399"))
    #expect(kept.first == "w")
    #expect(LivePreviewModel.tail("short") == "short")
  }

  @Test("the take model starts the preview with the take and ends it with the take", .timeLimit(.minutes(1)))
  func followsTheTake() async throws {
    let client = FakeAPIClient(now: { MemoFactory.now })
    let rig = OutboxRig(client: client)
    let coordinator = TakeLiveActivityCoordinator(
      activity: RecordingLiveActivity(), stack: rig.stack, created: rig.created)
    let controller = TakeController(
      stack: rig.stack, liveActivity: coordinator, outbox: rig.service, microphone: nil, canRecord: true,
      isConfigured: { true }, requestPermission: { true },
      preview: .fake(tap: rig.capture.recorder, engine: engine([.volatile("Hello"), .final("Hello there.")])))
    let take = TakeModel(controller: controller)
    let follower = Task { await take.run() }
    defer { follower.cancel() }

    await take.start()
    #expect(await waitFor { take.preview.isRunning })
    await rig.capture.recordWithoutClock(seconds: 0.5)
    #expect(await waitFor { take.preview.volatile == "Hello" })
    await rig.capture.recordWithoutClock(seconds: 0.5)
    #expect(await waitFor { take.preview.finalized == "Hello there." })

    await take.stop()
    #expect(await waitFor { !take.isActive })
    #expect(take.preview.finalized.isEmpty && !take.preview.isRunning, "the text goes with the take")
    #expect(take.failure == nil)
  }

  @Test("the fake composition root wires the preview: a take under -IrisFakeCapture runs it", .timeLimit(.minutes(1)))
  func compositionRootWiresThePreview() async throws {
    let root = CompositionRoot(arguments: ["-IrisFakeCapture"], credentials: InMemoryCredentialStore())
    let take = root.take
    let follower = Task { await take.run() }
    defer { follower.cancel() }

    await take.start()
    #expect(await waitFor { take.preview.isRunning }, "the root hands the take controller a preview source")
    #expect(
      await waitFor { take.preview.volatile.hasPrefix("Remind") || !take.preview.finalized.isEmpty },
      "the fake recognizer follows the fake microphone")

    await take.stop()
    #expect(await waitFor { !take.isActive })
    #expect(!take.preview.isRunning)
  }
}
