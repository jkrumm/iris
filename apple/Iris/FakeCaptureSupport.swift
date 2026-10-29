import Foundation
import IrisCapture
import IrisCore

/// The silent microphone of `-IrisFakeCapture`: while a take runs it feeds the fake recorder a second of "audio" every
/// 250 ms, so a hold of a few seconds closes real segments the outbox uploads.
final class FakeMicrophone {
  private let capture: FakeCapture
  private var task: Task<Void, Never>?

  init(capture: FakeCapture) {
    self.capture = capture
  }

  func start() {
    task?.cancel()
    // Owned by `task`; cancelled by `stop()`.
    task = Task { [capture] in
      while !Task.isCancelled {
        await capture.record(seconds: 1)
        try? await Task.sleep(for: .milliseconds(250))
      }
    }
  }

  /// Stops feeding and waits until the feeder has returned, so no frame arrives after the take is closed.
  func stop() async {
    let running = task
    task = nil
    running?.cancel()
    await running?.value
  }
}

/// The fake server's pipeline for `-IrisFakeCapture`: once a take is complete the memo walks to `notified` on a short
/// timer, with a transcript and a reply, so the app shows processing and then the answer (events included).
actor FakePipeline {
  private let client: FakeAPIClient
  private let step: Duration
  private var tasks: [String: Task<Void, Never>] = [:]

  init(client: FakeAPIClient, step: Duration = .milliseconds(1_200)) {
    self.client = client
    self.step = step
  }

  func run(_ memoID: String) {
    guard tasks[memoID] == nil else { return }
    // Owned by `tasks`; cancelled with the pipeline.
    tasks[memoID] = Task { [client, step] in
      let stages: [(MemoState, String?, String?)] = [
        (.transcribed, "This is the fake transcript of your voice memo.", nil),
        (.routed, nil, nil),
        (.notified, nil, "This is the fake answer to your voice memo."),
      ]
      for (state, transcript, reply) in stages {
        try? await Task.sleep(for: step)
        guard !Task.isCancelled else { return }
        try? await client.advance(memoID, to: state, transcript: transcript, replyText: reply)
      }
    }
  }

  func cancelAll() {
    for task in tasks.values { task.cancel() }
    tasks = [:]
  }
}

/// The uploader of `-IrisFakeCapture`: the real adapter over the fake API, and the fake pipeline starts on `complete`.
nonisolated struct FakePipelineUploader: SegmentUploader {
  let base: APIOutboxUploader
  let pipeline: FakePipeline

  func create(_ item: OutboxItem) async throws { try await base.create(item) }
  func upload(_ segment: ClosedSegment) async throws { try await base.upload(segment) }
  func delete(memoID: MemoID) async throws { try await base.delete(memoID: memoID) }

  func complete(memoID: MemoID, segmentCount: Int) async throws {
    try await base.complete(memoID: memoID, segmentCount: segmentCount)
    await pipeline.run(memoID.wireID)
  }
}
