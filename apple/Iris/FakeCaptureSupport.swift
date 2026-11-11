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

  /// Walks `memoID` to `notified`. A typed memo is created already transcribed (and keeps its own words as the transcript),
  /// so it only has the act and the answer ahead of it.
  func run(_ memoID: String, typed: Bool = false) {
    guard tasks[memoID] == nil else { return }
    // Owned by `tasks`; cancelled with the pipeline.
    tasks[memoID] = Task { [client, step] in
      // The reply is stored at `notified`, so the running turn stays on screen for two steps (UI tests on a slow runner
      // still catch it); the streamed text is the same words.
      let answer = typed ? "This is the fake answer to your message." : "This is the fake answer to your voice memo."
      let voice: [(MemoState, String?, String?)] = [
        (.transcribed, "This is the fake transcript of your voice memo.", nil),
        (.acted, nil, nil),
        (.notified, nil, answer),
      ]
      let text: [(MemoState, String?, String?)] = [
        (.acted, nil, nil),
        (.notified, nil, answer),
      ]
      for (state, transcript, reply) in typed ? text : voice {
        // The step before `acted` is `act` running: tools start and the reply streams in a burst just before it ends.
        if state == .acted {
          await Self.streamAct(memoID, answer: answer, step: step, client: client)
        } else {
          try? await Task.sleep(for: step)
        }
        guard !Task.isCancelled else { return }
        try? await client.advance(memoID, to: state, transcript: transcript, replyText: reply)
      }
    }
  }

  /// What a running `act` emits: three tool starts at about 15 %, 40 % and 65 % of the step, then (about 85 %) the answer in
  /// three deltas; it sleeps for the whole step, then the caller advances to `acted`.
  private static func streamAct(_ memoID: String, answer: String, step: Duration, client: FakeAPIClient) async {
    let tools = ["terminal", "web", "terminal"]
    let marks = [0.15, 0.40, 0.65, 0.85]
    var elapsed = 0.0
    for (index, mark) in marks.enumerated() {
      try? await Task.sleep(for: step * (mark - elapsed))
      guard !Task.isCancelled else { return }
      elapsed = mark
      if index < tools.count {
        client.emit(.memoActivity(MemoActivity(id: memoID, attempt: 1, tool: tools[index])))
        continue
      }
      for (offset, piece) in pieces(of: answer, count: 3).enumerated() {
        client.emit(.memoDelta(MemoDelta(id: memoID, attempt: 1, seq: offset + 1, text: piece)))
      }
    }
    try? await Task.sleep(for: step * (1 - elapsed))
  }

  /// `text` cut into `count` consecutive parts (the last takes the remainder), so they concatenate to `text`.
  private static func pieces(of text: String, count: Int) -> [String] {
    let size = max(1, text.count / count)
    var parts: [String] = []
    var rest = Substring(text)
    while parts.count < count - 1, !rest.isEmpty {
      parts.append(String(rest.prefix(size)))
      rest = rest.dropFirst(size)
    }
    parts.append(String(rest))
    return parts
  }

  func cancelAll() {
    for task in tasks.values { task.cancel() }
    tasks = [:]
  }
}

/// The uploader of `-IrisFakeCapture`: the real adapter over the fake API, and the fake pipeline starts on `complete` (a
/// typed memo: on its create).
nonisolated struct FakePipelineUploader: SegmentUploader {
  let base: APIOutboxUploader
  let pipeline: FakePipeline

  func create(_ item: OutboxItem) async throws {
    try await base.create(item)
    // A typed memo has no segments and no `complete`: the server drives it on from the create.
    if case .text = item.kind { await pipeline.run(item.memoID.wireID, typed: true) }
  }
  func upload(_ segment: ClosedSegment) async throws { try await base.upload(segment) }
  func delete(memoID: MemoID) async throws { try await base.delete(memoID: memoID) }

  func complete(memoID: MemoID, segmentCount: Int) async throws {
    try await base.complete(memoID: memoID, segmentCount: segmentCount)
    await pipeline.run(memoID.wireID)
  }
}
