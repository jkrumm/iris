import Foundation
import IrisCapture
import IrisCore
import os

/// The capture side of the app behind one lazy handle: the persistent outbox and the capture session around it. Built on
/// the first use, because loading the queue is `async`, and shared by the Settings queue, the composer, the thread's voice
/// reply and the start intent.
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

  private let parts: Parts
  private var building: Task<(Outbox, CaptureSession), Never>?
  private let logger = Logger(subsystem: "com.jkrumm.iris", category: "capture")

  init(_ parts: Parts) {
    self.parts = parts
  }

  func outbox() async -> Outbox { await built().0 }

  func session() async -> CaptureSession { await built().1 }

  private func built() async -> (Outbox, CaptureSession) {
    if let building { return await building.value }
    let parts = parts
    let task = Task { await Self.build(parts) }
    building = task
    return await task.value
  }

  private static func build(_ parts: Parts) async -> (Outbox, CaptureSession) {
    let outbox: Outbox
    do {
      outbox = try await Outbox(
        store: parts.store, uploader: parts.uploader, clock: parts.clock, policy: parts.policy,
        deletesFilesWhenDone: parts.deletesFilesWhenDone)
    } catch {
      // The store could not be read at all (not just decoded): run on a throwaway queue rather than not at all.
      Logger(subsystem: "com.jkrumm.iris", category: "capture")
        .error("outbox store unreadable, queue is not persisted: \(String(describing: error), privacy: .public)")
      outbox = await Self.memoryOutbox(parts)
    }
    await outbox.resume()
    let session = CaptureSession(
      session: parts.session, routes: parts.routes, recorder: parts.recorder, outbox: outbox, clock: parts.clock)
    return (outbox, session)
  }

  private static func memoryOutbox(_ parts: Parts) async -> Outbox {
    // `InMemoryOutboxStore.load()` cannot throw; the fallback only exists to satisfy the initializer's signature.
    let fallback = InMemoryOutboxStore()
    do {
      return try await Outbox(
        store: fallback, uploader: parts.uploader, clock: parts.clock, policy: parts.policy,
        deletesFilesWhenDone: parts.deletesFilesWhenDone)
    } catch {
      preconditionFailure("an in-memory outbox cannot fail to load: \(error)")
    }
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
