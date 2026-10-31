import Foundation
import IrisCapture
import IrisCore
import IrisTelemetry
import Observation

/// The text of the take screen's live preview: what the on-device recognizer has settled on (`finalized`) and what it is still
/// changing (`volatile`). Display only (TDD §4): never uploaded, stored, logged or put into telemetry; it lives as long as
/// the take and is gone with it.
///
/// A preview that cannot run (no source, the language or its model is not on the device, the recognizer fails) shows nothing and
/// never gets in the take's way: every failure ends here as "no preview".
@MainActor
@Observable
final class LivePreviewModel {
  /// The most characters of settled text kept: the screen shows the latest few lines, so the front of a long take is let go.
  static let maxCharacters = 600

  private(set) var finalized = ""
  private(set) var volatile = ""
  /// The recognizer is running for the take on screen, so the preview region is shown.
  private(set) var isRunning = false

  private let source: LivePreviewSource?
  private var memo: MemoID?
  private var task: Task<Void, Never>?

  init(source: LivePreviewSource?) {
    self.source = source
  }

  /// Starts the preview of `memo`. A preview that already ran (or failed) for this memo is not started again.
  func begin(memo: MemoID) {
    guard let source, memo != self.memo else { return }
    end()
    self.memo = memo
    // Owned by `task`; cancelled by `end()`, which every take ending reaches.
    task = Task { await run(source, memo: memo) }
  }

  /// The take is stopping, over or discarded: the stream is cancelled and the text goes with it.
  func end() {
    task?.cancel()
    task = nil
    memo = nil
    isRunning = false
    clearText()
  }

  private func clearText() {
    finalized = ""
    volatile = ""
  }

  private func run(_ source: LivePreviewSource, memo: MemoID) async {
    // Opened first so the take's first seconds are buffered while the recognizer's availability is looked up.
    let audio = await source.tap.openPreview()
    let locale = source.locale()
    guard await source.engine.isAvailable(for: locale) else {
      // Which language, never what was said.
      DeviceLog.shared.event(
        "preview.unavailable", memoID: memo, severity: .warn, ["locale": .string(locale.identifier(.bcp47))])
      return
    }
    guard !Task.isCancelled, self.memo == memo else { return }
    isRunning = true
    do {
      for try await update in source.engine.transcribe(audio, locale: locale) {
        guard self.memo == memo else { return }
        apply(update)
      }
    } catch is CancellationError {
      return
    } catch {
      guard self.memo == memo else { return }
      // The recognizer failed: the take goes on and the preview is simply gone. Logged here only (the engine rethrows), as
      // domain and code, never text.
      let failure = error as NSError
      DeviceLog.shared.event(
        "preview.stopped", memoID: memo, severity: .warn,
        ["error.domain": .string(failure.domain), "error.code": .int(failure.code)])
      isRunning = false
      clearText()
    }
  }

  private func apply(_ update: PreviewUpdate) {
    let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard update.isFinal else {
      volatile = text
      return
    }
    volatile = ""
    guard !text.isEmpty else { return }
    finalized = Self.tail(finalized.isEmpty ? text : "\(finalized) \(text)")
  }

  /// The last `maxCharacters` of `text`, cut at a word boundary.
  static func tail(_ text: String) -> String {
    guard text.count > maxCharacters else { return text }
    let kept = text.suffix(maxCharacters)
    guard let firstSpace = kept.firstIndex(of: " ") else { return String(kept) }
    return String(kept[kept.index(after: firstSpace)...])
  }
}
