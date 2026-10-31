import Foundation
import IrisCapture
import Testing

/// The preview tap on the fake recorder: an additive copy of the samples the recorder accepts, nothing while nobody listens.
@Suite("Preview tap", .timeLimit(.minutes(1)))
struct PreviewTapTests {
  private func recorder() -> FakeSegmentRecorder {
    FakeSegmentRecorder(
      directory: FileManager.default.temporaryDirectory.appending(path: "iris-tap-\(UUID().uuidString)"))
  }

  private func take(_ stream: AsyncStream<PreviewAudio>, count: Int) async -> [PreviewAudio] {
    var received: [PreviewAudio] = []
    for await audio in stream {
      received.append(audio)
      if received.count == count { break }
    }
    return received
  }

  @Test("samples fed to the recorder reach an open preview, at the recorder's sample rate")
  func feedsAnOpenPreview() async throws {
    let recorder = recorder()
    let stream = await recorder.openPreview()
    try await recorder.start(memoID: MemoID())
    await recorder.feed(frames: 4096)
    await recorder.feed(frames: 1000)

    let received = await take(stream, count: 2)
    #expect(received.map(\.samples.count) == [4096, 1000])
    #expect(received.allSatisfy { $0.sampleRate == 16_000 })
  }

  @Test("a paused take feeds the preview nothing, and a resumed one feeds it again")
  func pauseStopsFeeding() async throws {
    let recorder = recorder()
    let stream = await recorder.openPreview()
    try await recorder.start(memoID: MemoID())
    await recorder.pause()
    await recorder.feed(frames: 4096)
    await recorder.resume()
    await recorder.feed(frames: 123)

    #expect(await take(stream, count: 1).map(\.samples.count) == [123])
  }

  @Test("stopping the take ends the stream")
  func stopEndsTheStream() async throws {
    let recorder = recorder()
    let stream = await recorder.openPreview()
    try await recorder.start(memoID: MemoID())
    await recorder.feed(frames: 4096)
    try await recorder.stop()

    var count = 0
    for await _ in stream { count += 1 }  // returns because the stream finished
    #expect(count == 1)
  }

  @Test("opening the preview again ends the earlier stream")
  func reopeningReplaces() async throws {
    let recorder = recorder()
    let first = await recorder.openPreview()
    let second = await recorder.openPreview()
    try await recorder.start(memoID: MemoID())
    await recorder.feed(frames: 10)

    var firstCount = 0
    for await _ in first { firstCount += 1 }
    #expect(firstCount == 0)
    #expect(await take(second, count: 1).map(\.samples.count) == [10])
  }

  @Test("nothing is kept while no preview is open, and a released stream does not disturb the take or a later preview")
  func costsNothingUnwatched() async throws {
    let recorder = recorder()
    try await recorder.start(memoID: MemoID())
    await recorder.feed(frames: 4096)  // no preview: nothing buffered, nothing thrown

    do {
      let abandoned = await recorder.openPreview()
      _ = abandoned
    }
    await recorder.feed(frames: 4096)  // the consumer is gone: the feed closes itself
    await recorder.feed(frames: 4096)

    let later = await recorder.openPreview()
    await recorder.feed(frames: 77)
    #expect(await take(later, count: 1).map(\.samples.count) == [77], "the earlier audio is not replayed")
    try await recorder.stop()
  }
}
