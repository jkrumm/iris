import Foundation
import IrisCapture

/// The scripted recognizer of `-IrisFakeCapture` and the unit tests: every `chunksPerStep` buffers of the take's audio advance
/// the script by one step, so the text follows the audio that actually arrives (and stops while a take is paused).
nonisolated struct FakeLivePreviewEngine: LivePreviewEngine {
  enum Step: Sendable, Equatable {
    case volatile(String)
    case final(String)
    /// The recognizer fails mid-take.
    case fail
  }

  enum Failure: Error, Equatable { case scripted }

  /// The words the fake "hears", partial results first and a final one per sentence.
  static let demo: [Step] = [
    .volatile("Remind me"), .volatile("Remind me to call"), .volatile("Remind me to call the dentist"),
    .final("Remind me to call the dentist."),
    .volatile("and move"), .volatile("and move the Thursday"), .volatile("and move the Thursday meeting"),
    .final("and move the Thursday meeting."),
  ]

  var available = true
  var script = FakeLivePreviewEngine.demo
  var chunksPerStep = 2

  func isAvailable(for locale: Locale) async -> Bool { available }

  func transcribe(_ audio: AsyncStream<PreviewAudio>, locale: Locale) -> AsyncThrowingStream<PreviewUpdate, any Error> {
    let script = script
    let chunksPerStep = max(chunksPerStep, 1)
    return AsyncThrowingStream { continuation in
      // Owned by the stream: cancelled when its consumer stops.
      let task = Task {
        var chunks = 0
        var next = 0
        for await _ in audio {
          chunks += 1
          guard chunks % chunksPerStep == 0, next < script.count else { continue }
          let step = script[next]
          next += 1
          switch step {
          case .volatile(let text): continuation.yield(PreviewUpdate(text: text, isFinal: false))
          case .final(let text): continuation.yield(PreviewUpdate(text: text, isFinal: true))
          case .fail:
            continuation.finish(throwing: Failure.scripted)
            return
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
