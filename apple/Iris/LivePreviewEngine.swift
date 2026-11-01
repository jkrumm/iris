import Foundation
import IrisCapture

/// One piece of the live preview: text that is still changing (`isFinal == false`, it replaces the previous volatile text) or
/// text the recognizer has settled on (it is appended to what is final already).
nonisolated struct PreviewUpdate: Sendable, Equatable {
  let text: String
  let isFinal: Bool
}

/// The on-device recognizer behind the take screen's live preview (TDD §4). Display only: whatever it produces is never
/// uploaded, stored, logged or put into telemetry, and the server's transcript stays the truth.
/// Production: `SpeechAnalyzerPreviewEngine`. Fake: `FakeLivePreviewEngine`.
nonisolated protocol LivePreviewEngine: Sendable {
  /// Whether `locale` can be previewed right now without any download: the device supports the recognizer, the language is
  /// supported and its model is installed. Never starts a download (a model is hundreds of MB, and not on cellular unasked).
  func isAvailable(for locale: Locale) async -> Bool

  /// Recognizes `audio` until the stream ends or the consumer stops. A failure of the recognizer ends the stream with an error;
  /// a consumer that stops early cancels it. Only called after ``isAvailable(for:)`` returned `true`.
  func transcribe(_ audio: AsyncStream<PreviewAudio>, locale: Locale) -> AsyncThrowingStream<PreviewUpdate, any Error>
}

/// What the take controller needs to run a preview: the tap on the recorder's buffers, the recognizer and the language.
nonisolated struct LivePreviewSource: Sendable {
  let tap: any PreviewTap
  let engine: any LivePreviewEngine
  /// The take's language: the device's (the server's transcript language is its own business and stays the truth).
  var locale: @Sendable () -> Locale = { .current }

  /// The production recognizer over `tap`.
  static func speech(tap: any PreviewTap) -> LivePreviewSource {
    LivePreviewSource(tap: tap, engine: SpeechAnalyzerPreviewEngine())
  }

  /// The scripted recognizer of `-IrisFakeCapture`, fed by the fake recorder's silent tap.
  static func fake(
    tap: any PreviewTap, engine: FakeLivePreviewEngine = FakeLivePreviewEngine()
  ) -> LivePreviewSource {
    LivePreviewSource(tap: tap, engine: engine)
  }
}
