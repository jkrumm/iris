import AVFAudio
import Foundation
import IrisCapture
import Speech
import os

/// The production preview recognizer: `SpeechTranscriber` driven by a `SpeechAnalyzer` (iOS 26), fed from the recorder's tap.
///
/// Apple's analyzer does not run in the iOS Simulator (`SpeechTranscriber.isAvailable` is false there), so this adapter is
/// compile-checked on the simulator and proven on the phone only (`docs/spikes/device-checklist.md`); the model, the take
/// screen and the failure paths are tested on ``FakeLivePreviewEngine``. Speech recognition needs no permission of its own
/// (`NSSpeechRecognitionUsageDescription` belongs to `SFSpeechRecognizer`); the take already holds the microphone one.
///
/// Never logs, stores or forwards what it hears.
nonisolated struct SpeechAnalyzerPreviewEngine: LivePreviewEngine {
  private static let logger = Logger(subsystem: "com.jkrumm.iris", category: "preview")

  enum Failure: Error {
    case unsupportedLocale
    case noAudioFormat
  }

  func isAvailable(for locale: Locale) async -> Bool {
    guard SpeechTranscriber.isAvailable else { return false }
    guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return false }
    // `installedLocales` is the gate, not `AssetInventory.status`: no download is requested here, ever.
    let installed = await SpeechTranscriber.installedLocales
    return installed.contains { $0.identifier(.bcp47) == supported.identifier(.bcp47) }
  }

  func transcribe(_ audio: AsyncStream<PreviewAudio>, locale: Locale) -> AsyncThrowingStream<PreviewUpdate, any Error> {
    AsyncThrowingStream { continuation in
      // Owned by the stream: cancelled when its consumer stops, which also stops the analyzer (see `run`).
      let task = Task {
        do {
          try await Self.run(audio, locale: locale, into: continuation)
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func run(
    _ audio: AsyncStream<PreviewAudio>, locale: Locale,
    into continuation: AsyncThrowingStream<PreviewUpdate, any Error>.Continuation
  ) async throws {
    guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
      throw Failure.unsupportedLocale
    }
    let transcriber = SpeechTranscriber(
      locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
      throw Failure.noAudioFormat
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    // Bounded: a recognizer that falls behind drops the oldest audio instead of growing without limit.
    let (input, builder) = AsyncStream<AnalyzerInput>.makeStream(
      bufferingPolicy: .bufferingNewest(128))
    do {
      try await analyzer.start(inputSequence: input)
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          for try await result in transcriber.results {
            continuation.yield(PreviewUpdate(text: String(result.text.characters), isFinal: result.isFinal))
          }
        }
        group.addTask {
          let converter = LivePreviewConverter(target: format)
          for await chunk in audio {
            if let buffer = converter.convert(chunk) { builder.yield(AnalyzerInput(buffer: buffer)) }
          }
          builder.finish()
          if Task.isCancelled {
            await analyzer.cancelAndFinishNow()
          } else {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
          }
        }
        try await group.waitForAll()
      }
    } catch {
      builder.finish()
      await analyzer.cancelAndFinishNow()
      logger.notice("live preview stopped: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
      throw error
    }
  }
}
