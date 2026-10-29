import Foundation
import IrisCapture
import IrisCore
import os

/// The persistent queue could not be opened (its file is unreadable right now, for instance before the first unlock after
/// a reboot). Nothing is queued while this holds: a memo that "queued" into a throwaway list would be lost with the app.
nonisolated enum CaptureStackError: Error, Equatable, Sendable {
  case queueUnavailable
}

/// How a reset of the unreadable outbox ended, short of throwing (which means nothing was touched).
nonisolated enum OutboxResetOutcome: Equatable, Sendable {
  /// The file is set aside and a fresh outbox is open.
  case reset
  /// The file is set aside (and kept) but the fresh outbox could not be opened; the next open tries again.
  case setAsideNotOpen
  /// Nothing was changed.
  case notReset
}

/// Why Settings can or cannot use the queue.
nonisolated enum OutboxAvailability: Equatable, Sendable {
  case available
  /// Cannot be opened right now (before the first unlock, say); asking again retries.
  case unavailable
  /// The saved file is there but cannot be decoded. Only a reset gets past this, and the reset keeps the file.
  case unreadable
}

/// The capture side of the app behind one lazy handle: the persistent outbox and the capture session around it. Built on
/// the first use, because loading the queue is `async`, and shared by the Settings queue, the composer, the thread's voice
/// reply and the start intent.
///
/// When the queue cannot be loaded the stack stays unbuilt and every caller gets `queueUnavailable`; the next call tries the
/// real store again, so `resume()` (and a pull to refresh) is the retry. There is no in-memory stand-in. A file that cannot
/// be decoded stays unreadable until ``resetOutbox()``, which renames it aside (kept, never deleted) and opens a fresh queue.
///
/// Every time the queue opens, the capture directory is swept: segment files no saved record names are adopted by their take
/// or moved into `quarantine/` there. Nothing is deleted.
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
    /// Where the recorder writes segment files; `nil` skips the startup sweep (fakes).
    var captureDirectory: URL?
  }

  private typealias Built = (outbox: Outbox, session: CaptureSession)

  private let parts: Parts
  private var built: Built?
  private var building: Task<Result<Built, any Error>, Never>?
  /// Why the last attempt to open the queue failed; `nil` once it is open.
  private var lastFailure: (any Error)?
  private var isResetting = false
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
    await availability() == .available
  }

  /// Opens the queue when it is not open yet, and says how that went.
  func availability() async -> OutboxAvailability {
    if (try? await open()) != nil { return .available }
    return (lastFailure as? OutboxStoreError) == .undecodable ? .unreadable : .unavailable
  }

  /// Sets the unreadable queue file aside under a timestamped name (kept next to it, with the segment files it names) and
  /// opens a fresh queue. Throws `queueUnavailable` when nothing was changed: the queue is not unreadable, or the file could
  /// not be moved. `setAsideNotOpen` says the file did move but the fresh queue would not open.
  func resetOutbox() async throws -> OutboxResetOutcome {
    guard await availability() == .unreadable, !isResetting else { throw CaptureStackError.queueUnavailable }
    // Other callers wait out the move: a build in the middle of it would read the file that is being renamed.
    isResetting = true
    let moved: URL?
    do {
      moved = try await parts.store.quarantine()
    } catch {
      isResetting = false
      logger.error("outbox file not set aside: \(String(describing: error), privacy: .public)")
      throw CaptureStackError.queueUnavailable
    }
    isResetting = false
    logger.notice("outbox reset, the old queue is kept as \(moved?.lastPathComponent ?? "-", privacy: .public)")
    do {
      _ = try await open()
      return .reset
    } catch {
      logger.error("outbox set aside but a new one did not open: \(String(describing: error), privacy: .public)")
      return .setAsideNotOpen
    }
  }

  /// The queue files earlier resets set aside, for Diagnostics to share.
  func quarantinedFiles() async -> [URL] {
    await parts.store.quarantined()
  }

  private func open() async throws -> Built {
    if let built { return built }
    guard !isResetting else { throw CaptureStackError.queueUnavailable }
    let task = building ?? Task { [parts, logger] in await Self.build(parts, logger: logger) }
    building = task
    let result = await task.value
    // Callers that awaited the same build all get here, and one of them may already have started the next build after a
    // failure: only the build this call waited for is cleared, so two builds never run over the same queue file.
    if building == task { building = nil }
    switch result {
    case .failure(let error):
      lastFailure = error
      throw CaptureStackError.queueUnavailable
    case .success(let opened):
      lastFailure = nil
      // The first caller that gets here keeps the stack; a later one finds it and returns the same.
      if let built { return built }
      built = opened
      return opened
    }
  }

  private static func build(_ parts: Parts, logger: Logger) async -> Result<Built, any Error> {
    let outbox: Outbox
    do {
      outbox = try await Outbox(
        store: parts.store, uploader: parts.uploader, clock: parts.clock, policy: parts.policy,
        deletesFilesWhenDone: parts.deletesFilesWhenDone)
    } catch {
      logger.error("outbox store cannot be opened, nothing is queued: \(String(describing: error), privacy: .public)")
      return .failure(error)
    }
    if let directory = parts.captureDirectory {
      // Before anything is sent or recorded: a file written but never saved belongs to a take of an earlier run.
      await outbox.sweepOrphans(in: directory, quarantineTo: directory.appending(path: "quarantine"))
    }
    await outbox.resume()
    let session = CaptureSession(
      session: parts.session, routes: parts.routes, recorder: parts.recorder, outbox: outbox, clock: parts.clock)
    return .success((outbox, session))
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
