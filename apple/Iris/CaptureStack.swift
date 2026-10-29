import Foundation
import IrisCapture
import IrisCore
import os

/// The persistent queue could not be opened (its file is unreadable right now, for instance before the first unlock after
/// a reboot). Nothing is queued while this holds: a memo that "queued" into a throwaway list would be lost with the app.
nonisolated enum CaptureStackError: Error, Equatable, Sendable {
  case queueUnavailable
}

/// The capture side of the app behind one lazy handle: the persistent outbox and the capture session around it. Built on
/// the first use, because loading the queue is `async`, and shared by the Settings queue, the composer, the thread's voice
/// reply and the start intent.
///
/// When the queue cannot be loaded the stack stays unbuilt and every caller gets `queueUnavailable`; the next call tries the
/// real store again, so `resume()` (and a pull to refresh) is the retry. There is no in-memory stand-in.
actor CaptureStack {
  struct Parts: Sendable {
    let session: any AudioSessionController
    let routes: any RouteManager
    let recorder: any SegmentRecorder
    let clock: any CaptureClock
    let store: any OutboxStore
    let uploader: any SegmentUploader
    var policy = OutboxPolicy()
    /// Fakes keep a take's files until the process ends; production deletes them once the server has the memo.
    var deletesFilesWhenDone = true
  }

  private typealias Built = (outbox: Outbox, session: CaptureSession)

  private let parts: Parts
  private var built: Built?
  private var building: Task<Built?, Never>?
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "capture")

  init(_ parts: Parts) {
    self.parts = parts
  }

  /// The route manager the session records through (the microphone list of the take screen reads it).
  nonisolated var routes: any RouteManager { parts.routes }

  func outbox() async throws -> Outbox { try await open().outbox }

  func session() async throws -> CaptureSession { try await open().session }

  /// Whether the queue is open, trying to open it when it is not: the state Settings shows.
  func isAvailable() async -> Bool {
    (try? await open()) != nil
  }

  private func open() async throws -> Built {
    if let built { return built }
    let task = building ?? Task { [parts, logger] in await Self.build(parts, logger: logger) }
    building = task
    let result = await task.value
    // Callers that awaited the same build all get here, and one of them may already have started the next build after a
    // failure: only the build this call waited for is cleared, so two builds never run over the same queue file.
    if building == task { building = nil }
    guard let result else { throw CaptureStackError.queueUnavailable }
    built = result
    return result
  }

  private static func build(_ parts: Parts, logger: Logger) async -> Built? {
    let outbox: Outbox
    do {
      outbox = try await Outbox(
        store: parts.store, uploader: parts.uploader, clock: parts.clock, policy: parts.policy,
        deletesFilesWhenDone: parts.deletesFilesWhenDone)
    } catch {
      logger.error("outbox store cannot be opened, nothing is queued: \(String(describing: error), privacy: .public)")
      return nil
    }
    await outbox.resume()
    let session = CaptureSession(
      session: parts.session, routes: parts.routes, recorder: parts.recorder, outbox: outbox, clock: parts.clock)
    return (outbox, session)
  }
}

/// Stands in for the recorder when the engine recorder could not be built: every start fails, the controls stay disabled.
nonisolated struct UnavailableSegmentRecorder: SegmentRecorder {
  let events = AsyncStream<CaptureEvent> { $0.finish() }
  let levels = AsyncStream<Float> { $0.finish() }

  func start(memoID: MemoID) async throws { throw CaptureError.engineFailure("the recorder is unavailable") }
  func stop() async throws { throw CaptureError.notRecording }
  func rotate(for reason: RotationReason) async {}
  func pause() async {}
  func resume() async {}
}
