import Foundation

/// A slice of the take's audio for the live preview: the samples the segment recorder just received, 16 kHz mono Float32.
public struct PreviewAudio: Sendable, Equatable {
  public let samples: [Float]
  public let sampleRate: Double

  public init(samples: [Float], sampleRate: Double) {
    self.samples = samples
    self.sampleRate = sampleRate
  }
}

/// An additive tap on the buffers the segment recorder already receives, for the on-device live preview (TDD §4).
///
/// Read-only by construction: the tap never touches segment rotation, the writer or the outbox, and nothing is buffered
/// while no stream is open. Samples arrive after the recorder's own pause gate, so a paused take feeds nothing, and every
/// stream ends when the take stops or is cancelled.
/// Production: `AVAudioEngineSegmentRecorder`. Fake: `FakeSegmentRecorder`.
public protocol PreviewTap: Sendable {
  /// Opens the stream for the take in progress (or the next one). One consumer: opening again ends the earlier stream.
  /// The stream is bounded and drops the oldest audio when the consumer falls behind: the preview is display only.
  func openPreview() async -> AsyncStream<PreviewAudio>
}

/// The recorder-side half of ``PreviewTap``: one optional bounded stream, fed from the recorder's actor.
struct PreviewFeed {
  /// About ten seconds of tap buffers.
  static let bufferedChunks = 128

  private var sink: AsyncStream<PreviewAudio>.Continuation?

  mutating func open() -> AsyncStream<PreviewAudio> {
    sink?.finish()
    let (stream, continuation) = AsyncStream.makeStream(
      of: PreviewAudio.self, bufferingPolicy: .bufferingNewest(Self.bufferedChunks))
    sink = continuation
    return stream
  }

  /// A no-op while nobody listens. A consumer that went away (its stream was released) closes the feed.
  mutating func send(_ audio: @autoclosure () -> PreviewAudio) {
    guard let sink else { return }
    if case .terminated = sink.yield(audio()) { self.sink = nil }
  }

  mutating func close() {
    sink?.finish()
    sink = nil
  }
}
